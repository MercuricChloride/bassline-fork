## store.nim
## =========================================================================
## An append-only, copy-on-write B+tree holding a monotone set of
## canonically-encoded (CE) byte strings. Key-only: an element's bytes are
## simultaneously its key, its value, and its identity. The storage layer
## never interprets elements — it only memcmp's them.
##
## Design record (decisions this file implements):
##
##   * Backends. The tree never talks to the OS directly: all page
##     backing goes through a tiny arena interface (backends/pages.nim).
##     MmapArena is the durable file-backed instance, MemArena a pure
##     in-memory one; Db[A] takes the backend on init. One format, one
##     tree, two substrates — the same insert sequence produces
##     byte-identical pages on both, and a mem store dumped to a file IS
##     a store file.
##   * COW, append-only, CouchDB-style commit headers. Pages are never
##     overwritten once published; a commit writes fresh pages past the
##     published high-water mark, then appends a commit-header page. Crash
##     recovery = backward scan for the last valid header. Every header
##     ever written remains a valid historical root (snapshots for free).
##   * No freelist. Monotone semantics ⇒ no deletes; append-only COW ⇒ no
##     reclamation. Allocation is "increment pageCount". Compaction, if
##     ever wanted, is an offline live-tree copy (bulk load in key order).
##   * No fragBytes / in-page free tracking beyond cellStart: committed
##     pages are frozen; dirty pages are built in memory and written once.
##   * Key-only cells. Leaf cells hold ELEMENTS (real CE values); interior
##     cells hold SEPARATORS (suffix-truncated byte strings,
##     never required to be valid CE). Two-sorted structure.
##   * Order: memcmp over min length, ties broken shorter-first. Elements
##     under CE are prefix-free so element/element ties never occur; the
##     shorter-first rule serves separators and prefix probes.
##   * uint32 element-length cap (mirrors CE's scalar tier ceiling — but
##     note this caps whole ELEMENTS incl. containers, which CE itself
##     does not: a deliberate storage-imposed limit, not a derived fact).
##
## Known bets / pitfalls (named, per the running checklist):
##
##   * Native-endian on-disk integers. Fine on your machines (LE); a
##     portable format wants explicit LE load/store helpers. Retrofit is
##     mechanical but touches every accessor — decide before shipping.
##   * Packed structs cast onto arbitrary page offsets: byte-safe codegen
##     via {.packed.}, tolerated by x86/arm64 regardless. The pedantic
##     alternative is copyMem into locals.
##   * Slot offsets are uint16 ⇒ PageSize ≤ 32768 (static-asserted).
##     cellStart is uint32 precisely because empty-page = PageSize = 16384
##     doesn't fit in uint16.
##   * MaxSep: a split whose boundary elements share a prefix longer than
##     MaxSep asserts out. Real CE data makes this vanishingly unlikely
##     (discriminating bytes come early); it is not impossible.
##   * Single writer process. The mmap backend enforces it with an
##     exclusive non-blocking flock taken at create/open and released
##     with the fd, so a second process opening the same store fails
##     fast instead of silently corrupting it. In-process readers share
##     the Db object; cross-process READERS would still need a
##     file-level story of their own (they *can* safely read any
##     committed root, but nothing here coordinates that).
##   * Cursors are invalidated by inserts in the same txn (dirty pages
##     mutate in place inside a txn — COW governs only the
##     committed/dirty boundary, not intra-txn mutation).
##   * Elements with packed tails are NOT contiguous in the arena;
##     zero-copy spans exist only for fully-inline elements
##     (currentIsInline / currentSpan). Tail storage is byte-exact
##     (v2 arena packing); residual waste is one partial arena page
##     per committing txn.
##
## Backend-specific bets (fixed mapping, msync/mprotect rounding,
## F_FULLFSYNC, disk-full reservation) live in backends/mmaparena.nim.
##
## Compile-time knobs: -d:PageSize=256 shrinks pages so the test suite
## can force deep trees / interior splits / root splits cheaply;
## -d:ReservedGb=N sizes both backends' address ceilings.
## =========================================================================
import ./backends/[pages, mmaparena, memarena]
export pages, mmaparena, memarena
import checksums/sha3
export sha3
# -------------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------------

const
  SbMagic = 0x42534C42'u32          # "BLSB" little-endian in a hex dump
  ChMagic = 0x48434C42'u32          # "BLCH"
  FormatVersion = 2'u32

# -------------------------------------------------------------------------
# On-disk types
#
# Everything on disk is either a fixed struct (headers, cell prefixes) or
# raw bytes addressed by offset arithmetic. The structs below are LENSES
# cast onto regions of a page buffer — none of them is ever instantiated
# as a value. Page numbers are the only kind of pointer; byte offset of
# page p is always p * PageSize.
# -------------------------------------------------------------------------

type
  PageKind {.size: 1.} = enum
    pkNone     = 0                  # zeroed memory never decodes as a
                                    # valid page — mirror of CE's tag-0 rule
    pkInterior = 1
    pkLeaf     = 2
    pkArena    = 3                  # packed tail arena (v2)

  # 12 bytes; fields happen to be naturally aligned even unpacked, but
  # packed states the layout as an invariant rather than an accident.
  PageHeader {.packed.} = object
    kind: PageKind
    flags: uint8                    # unused; reserves the byte
    cellCount: uint16
    cellStart: uint32               # offset of lowest cell byte; cells
                                    # grow DOWN from PageSize toward the
                                    # slot array. uint32 because the empty
                                    # value is PageSize itself (16384).
    rightChild: PageN               # interior only: the (n+1)th child

  # Leaf cell = one ELEMENT. Key-only: `len` is the whole element's
  # length; data holds the inline portion (all of it, or exactly
  # MaxLocal bytes with the tail packed byte-exact into the arena --
  # a contiguous byte range starting at (tailPg, tailOff), spanning
  # next-linked arena pages as needed; its length is derived:
  # len - MaxLocal).
  LeafObj {.packed.} = object
    tailPg: PageN                   # 0 = fully inline
    tailOff: uint16                 # tail start within its arena page
    len: uint32                     # total element length
    data: UncheckedArray[byte]

  # Interior cell = one SEPARATOR + left child. Invariant, for cell i:
  #   every element in child_i  <  sep_i  <= every element to its right
  # Separators are fenceposts: shortest discriminating prefixes, not
  # elements, and never consulted for anything but routing.
  InteriorObj {.packed.} = object
    child: PageN
    sepLen: uint16
    sep: UncheckedArray[byte]

  # Arena pages hold element TAILS packed back to back, byte-exact --
  # this is the v2 chain-packing design. Tails of successive inserts
  # within one txn share pages; a tail that outgrows the current page
  # continues in a fresh one via `next`. Once the txn commits, arena
  # pages freeze like every other page; the next txn opens its own.
  # No refcounts, no fragmentation, no reclamation: monotonicity makes
  # sharing free. Residual waste = one partial arena page per txn.
  # The kind byte keeps every page in the file self-identifying.
  ArenaObj {.packed.} = object
    kind: PageKind                  # pkArena
    pad: array[3, uint8]
    next: PageN                     # continuation page for spanning
                                    # tails (0 = none opened yet)
    used: uint32                    # bytes packed so far (integrity /
                                    # future fsck; readers derive)
    data: UncheckedArray[byte]

  # Page 0, written once at create. Identifies the file and pins its
  # geometry so a mismatched PageSize build refuses to open it.
  Superblock {.packed.} = object
    magic: uint32
    version: uint32
    pageSize: uint32

  # Commit headers are appended at page boundaries after the pages they
  # publish. `pageCount` counts pages INCLUDING this header page, which
  # doubles as a validity check: a header at page p must claim p+1.
  CommitHeader {.packed.} = object
    magic: uint32
    version: uint32
    txid: uint64
    root: PageN                     # 0 = empty tree
    pageCount: PageN
    digest: array[32, byte]

const
  HeaderSize = sizeof(PageHeader)                     # 12
  LeafFixed  = sizeof(LeafObj)                        # 8
  IntFixed   = sizeof(InteriorObj)                    # 6
  ArenaHead  = sizeof(ArenaObj)                       # 12
  ArenaCap*  = PageSize - ArenaHead

  # Inline payload cap: chosen so at least ~4 leaf cells fit a page,
  # keeping fanout sane even with fat elements (the SQLite maxLocal
  # move). Elements longer than this pack exactly their tail into the
  # arena — the inline prefix stays MaxLocal bytes, which is what makes
  # comparisons against big elements almost always resolve without
  # touching the tail (first differing byte comes early).
  MaxLocal* = (PageSize - HeaderSize) div 4 - LeafFixed - 2

  # Separators must always fit inline; any prefix that discriminates is
  # legal, so this is a cap on shared-prefix length at split boundaries.
  MaxSep* = MaxLocal

static:
  doAssert sizeof(PageHeader) == 12
  doAssert sizeof(LeafObj) == 10
  doAssert sizeof(InteriorObj) == 6
  doAssert sizeof(ArenaObj) == 12
  doAssert sizeof(Superblock) == 12
  doAssert sizeof(CommitHeader) == 56
  doAssert MaxLocal > 16

static:
  doAssert PageSize >= sizeof(CommitHeader) * 4, "page too small to hold minimal cells"
  doAssert PageSize <= 32768, "slot offsets are uint16; widen SlotN first"

proc headerHash(ch: CommitHeader): array[32, byte] =
  var
    hash = initSha3_256()
    tmp = ch
  hash.update toOpenArray(
      cast[ptr UncheckedArray[char]](addr tmp), 0,
      sizeof(CommitHeader) - sizeof(CommitHeader.digest) - 1)
  cast[array[32, byte]](hash.digest())


# -------------------------------------------------------------------------
# Byte comparison
#
# The single point of key semantics in the whole engine. memcmp over the
# common prefix; ties broken shorter-first. For complete CE elements the
# tie branch never fires (self-delimiting ⇒ prefix-free); it exists for
# separators and prefix probes, and its direction (shorter sorts first)
# is what makes "sep is a prefix of right's first key" a valid separator
# and "seek to prefix" a lower bound for the prefix's family.
# -------------------------------------------------------------------------

proc cmpBytes*(a, b: openArray[byte]): int =
  let n = min(a.len, b.len)
  if n > 0:
    let r = cmpMem(unsafeAddr a[0], unsafeAddr b[0], n)
    if r != 0: return r
  a.len - b.len

# -------------------------------------------------------------------------
# Db object
#
# Generic over the backend A. The backend owns page backing and
# durability; the Db owns the tree and the commit protocol. Everything
# below speaks page numbers, resolved to stable addresses through the
# backend's pageAt.
# -------------------------------------------------------------------------

type
  Db*[A] = ref object
    backend*: A
    root: PageN                     # published root (0 = empty)
    pageCount: PageN                # published high-water mark = allocator
    txid: uint64
    inTxn: bool
    workRoot: PageN                 # root-in-progress during a txn
    arenaPg: PageN                  # open tail-arena page (0 = none)
    arenaUsed: int                  # bump pointer within it
    txnStart: PageN                 # pageCount at begin(); the dirty
                                    # boundary: pgno >= txnStart ⇔ dirty
    nextPage: PageN                 # allocation cursor during a txn

  Snapshot*[A] = object
    ## An immutable view of one tree state: a backend view, a root, and
    ## a page limit. A value type with no ref and no destructor -- copy
    ## it, hand it to another thread or a malebolgia spawn. A committed
    ## snapshot is safe to read concurrently with a running write txn
    ## without locks: readers never touch pages >= limit, the writer
    ## never touches pages < txnStart, and the backend's address
    ## stability guarantee (fixed mapping / immortal chunks) plus seal
    ## enforcement covers the rest. Valid until close().
    backend: A
    root*: PageN
    limit: PageN

# -------------------------------------------------------------------------
# Page access: page numbers resolved through the backend. Dirtiness is
# ARITHMETIC — append-only allocation means a page is dirty iff its
# number is at or past this txn's starting high-water mark. The one COW
# rule: never write through a pointer for a pgno < txnStart unless it
# came from dirtyCopy.
# -------------------------------------------------------------------------

proc snapshot*[A](db: Db[A]): Snapshot[A] =
  ## The committed state as a shareable value (see Snapshot). This is
  ## the handle parallel readers should hold; it is unaffected by a
  ## concurrently running write transaction until that txn commits and
  ## a fresh snapshot is taken.
  Snapshot[A](backend: db.backend, root: db.root, limit: db.pageCount)

proc rsnap[A](db: Db[A]): Snapshot[A] =
  ## Internal: the LIVE read view. Inside a txn this includes dirty
  ## pages and the work-in-progress root -- correct for the owning
  ## thread, NOT safe to share (dirty pages mutate in place).
  if db.inTxn: Snapshot[A](backend: db.backend, root: db.workRoot,
                           limit: db.nextPage)
  else: Snapshot[A](backend: db.backend, root: db.root, limit: db.pageCount)

proc getPage[A](s: Snapshot[A]; pgno: PageN): Page =
  doAssert pgno >= 2 and pgno < s.limit,
    "page " & $pgno & " outside snapshot range"
  pageAt(s.backend, pgno)

proc getPage[A](db: Db[A]; pgno: PageN): Page = db.rsnap.getPage(pgno)

proc allocPage[A](db: Db[A]): (PageN, Page) =
  ## The entire allocator: bump the cursor (and the backend, when the
  ## cursor outruns it). No freelist — see header. Zeroed so unused
  ## regions of pages are deterministic bytes on disk (fresh backend
  ## ranges are zeros anyway; this also covers ranges recycled after a
  ## rollback).
  doAssert db.inTxn
  let pgno = db.nextPage
  inc db.nextPage
  ensure(db.backend, int(db.nextPage))
  let pg = pageAt(db.backend, pgno)
  zeroMem(pg, PageSize)
  (pgno, pg)

proc dirtyCopy[A](db: Db[A]; pgno: PageN): (PageN, Page) =
  ## COW step: a committed page about to be modified gets a fresh page
  ## number and a private copy. Pages already at/past txnStart are this
  ## txn's own and mutate in place: within a txn we are an ordinary
  ## in-place b-tree; COW governs only the committed/dirty boundary. The
  ## superseded committed page becomes unreferenced garbage in the new
  ## root (never reclaimed).
  if pgno >= db.txnStart: return (pgno, db.getPage(pgno))
  let src = db.getPage(pgno)
  let (np, pg) = db.allocPage()
  copyMem(pg, src, PageSize)
  (np, pg)

proc advise*(db: Db[MmapArena]; adv: MapAdvice) =
  ## mmap-backend extra: hint the kernel's pagein policy (see
  ## mmaparena.advise). Meaningless for MemArena, so not defined there.
  advise(db.backend, adv)

# -------------------------------------------------------------------------
# In-page primitives: the slotted page.
#
#   0                                                          PageSize
#   +------------+---------------------+...........+------------------+
#   | PageHeader | slots[0..count-1]   |   free    | cells (unordered)|
#   +------------+---------------------+...........+------------------+
#                ^                     ^           ^
#                HeaderSize            freeStart   cellStart
#
# Sorted order lives ONLY in the slot array; cells sit wherever the
# bump-down allocator put them. Insertion shifts 2-byte slots, never
# payloads.
# -------------------------------------------------------------------------

template hdr(pg: Page): ptr PageHeader =
  cast[ptr PageHeader](addr pg[0])

template slots(pg: Page): ptr UncheckedArray[uint16] =
  cast[ptr UncheckedArray[uint16]](addr pg[HeaderSize])

proc freeStartOf(pg: Page): int =
  HeaderSize + hdr(pg).cellCount.int * 2

proc freeSpace(pg: Page): int =
  hdr(pg).cellStart.int - freeStartOf(pg)

template leafAt(pg: Page; i: int): ptr LeafObj =
  cast[ptr LeafObj](addr pg[slots(pg)[i].int])

template intAt(pg: Page; i: int): ptr InteriorObj =
  cast[ptr InteriorObj](addr pg[slots(pg)[i].int])

template sepOpen(c: ptr InteriorObj): untyped =
  toOpenArray(cast[ptr UncheckedArray[byte]](addr c.sep[0]),
              0, c.sepLen.int - 1)

proc initPage(pg: Page; kind: PageKind) =
  zeroMem(pg, PageSize)
  hdr(pg).kind = kind
  hdr(pg).cellStart = uint32(PageSize)

proc getChildAt(pg: Page; i: int): PageN =
  ## Child index i ranges 0..cellCount; index cellCount is rightChild —
  ## the (n+1)th pointer for n separators.
  if i < hdr(pg).cellCount.int: intAt(pg, i).child
  else: hdr(pg).rightChild

proc setChildAt(pg: Page; i: int; c: PageN) =
  if i < hdr(pg).cellCount.int: intAt(pg, i).child = c
  else: hdr(pg).rightChild = c

proc addBlob(pg: Page; idx: int; blob: openArray[byte]) =
  ## Insert a pre-built cell (raw bytes) at sorted position idx: carve
  ## space off the top, drop the cell in, open the slot array by one.
  let need = blob.len + 2
  doAssert freeSpace(pg) >= need, "addBlob without room (caller bug)"
  let h = hdr(pg)
  h.cellStart -= uint32(blob.len)
  copyMem(addr pg[h.cellStart.int], unsafeAddr blob[0], blob.len)
  let n = h.cellCount.int
  let sl = slots(pg)
  if idx < n:
    moveMem(addr sl[idx + 1], addr sl[idx], (n - idx) * 2)
  sl[idx] = uint16(h.cellStart)
  h.cellCount = uint16(n + 1)

# -------------------------------------------------------------------------
# The tail arena
#
# Element tails (bytes past MaxLocal) live packed back to back in arena
# pages. The writer keeps one open arena per txn with a bump pointer; a
# tail records only its start (page, offset) -- its length is derived
# from the cell's `len`, and it runs contiguously across next-linked
# pages. Storage cost for oversized elements is thereby byte-exact
# (amp ~1.0x) instead of page-granular (2x+ for ~10KB elements under
# the v1 chain design, the SQLite/LMDB overhead class).
# -------------------------------------------------------------------------

proc arenaOpen[A](db: Db[A]): Page =
  ## Ensure an open, non-full arena page; link continuations.
  if db.arenaPg == 0 or db.arenaUsed >= ArenaCap:
    let prev = db.arenaPg
    let (pg, p) = db.allocPage()
    cast[ptr ArenaObj](p).kind = pkArena
    if prev != 0:
      cast[ptr ArenaObj](db.getPage(prev)).next = pg
    db.arenaPg = pg
    db.arenaUsed = 0
    return p
  db.getPage(db.arenaPg)

proc tailWrite[A](db: Db[A]; rest: openArray[byte]): (PageN, uint16) =
  ## Pack a tail into the arena, spanning pages as needed; returns the
  ## start coordinates. Only ever called inside a txn on dirty arena
  ## pages (intra-txn mutation is in-place per the COW model).
  doAssert rest.len > 0
  var p = db.arenaOpen()
  result = (db.arenaPg, uint16(db.arenaUsed))
  var off = 0
  while off < rest.len:
    let n = min(ArenaCap - db.arenaUsed, rest.len - off)
    let ar = cast[ptr ArenaObj](p)
    copyMem(addr ar.data[db.arenaUsed], unsafeAddr rest[off], n)
    db.arenaUsed += n
    ar.used = uint32(db.arenaUsed)
    off += n
    if off < rest.len:
      p = db.arenaOpen()            # full: open + link continuation

proc inlineLenOf(c: ptr LeafObj): int =
  if c.tailPg == 0: c.len.int else: MaxLocal

proc leafCellSize(c: ptr LeafObj): int =
  LeafFixed + inlineLenOf(c)

proc intCellSize(c: ptr InteriorObj): int =
  IntFixed + c.sepLen.int

proc readElem[A](s: Snapshot[A]; c: ptr LeafObj): seq[byte] =
  ## Materialize an element: inline prefix, then the packed tail.
  let total = c.len.int
  result = newSeq[byte](total)
  let inl = inlineLenOf(c)
  if inl > 0:
    copyMem(addr result[0], addr c.data[0], inl)
  var off = inl
  var pn = c.tailPg
  var po = c.tailOff.int
  while off < total:
    let ar = cast[ptr ArenaObj](s.getPage(pn))
    doAssert ar.kind == pkArena, "corrupt tail"
    let n = min(ArenaCap - po, total - off)
    copyMem(addr result[off], addr ar.data[po], n)
    off += n
    pn = ar.next
    po = 0
  doAssert off == total, "truncated tail"

proc cmpProbeCell[A](s: Snapshot[A]; probe: openArray[byte];
                     c: ptr LeafObj): int =
  ## Compare a fully in-memory probe against a stored element, walking
  ## the packed tail only if the inline prefix ties — which for real
  ## data almost never happens (differing bytes come early).
  let inl = inlineLenOf(c)
  let total = c.len.int
  let n = min(probe.len, inl)
  if n > 0:
    let r = cmpMem(unsafeAddr probe[0], addr c.data[0], n)
    if r != 0: return r
  if probe.len <= inl or c.tailPg == 0:
    return probe.len - total
  var off = inl
  var pn = c.tailPg
  var po = c.tailOff.int
  while off < total and off < probe.len:
    let ar = cast[ptr ArenaObj](s.getPage(pn))
    let m = min(min(ArenaCap - po, total - off), probe.len - off)
    if m > 0:
      let r = cmpMem(unsafeAddr probe[off], addr ar.data[po], m)
      if r != 0: return r
    off += m
    po += m
    if po >= ArenaCap:
      pn = ar.next
      po = 0
  probe.len - total

proc elemHasPrefix[A](s: Snapshot[A]; c: ptr LeafObj;
                      prefix: openArray[byte]): bool =
  if prefix.len > c.len.int: return false
  let inl = inlineLenOf(c)
  let n = min(prefix.len, inl)
  if n > 0 and cmpMem(unsafeAddr prefix[0], addr c.data[0], n) != 0:
    return false
  if prefix.len <= inl: return true
  var off = inl
  var pn = c.tailPg
  var po = c.tailOff.int
  while off < prefix.len:
    let ar = cast[ptr ArenaObj](s.getPage(pn))
    let m = min(ArenaCap - po, prefix.len - off)
    if cmpMem(unsafeAddr prefix[off], addr ar.data[po], m) != 0:
      return false
    off += m
    po += m
    if po >= ArenaCap:
      pn = ar.next
      po = 0
  true

# -------------------------------------------------------------------------
# Search within pages
# -------------------------------------------------------------------------

proc intDescendIdx(pg: Page; probe: openArray[byte]): int =
  ## First i with probe < sep_i (descend child i); cellCount if none
  ## (descend rightChild). A probe equal to sep_i goes RIGHT, matching
  ## the invariant left < sep <= right. The same rule serves insert,
  ## member, and prefix seek — a probe that is a byte-prefix of elements
  ## sorts before all of them (shorter-first), so lower-bound descent
  ## lands at the start of the prefix's contiguous run.
  var lo = 0
  var hi = hdr(pg).cellCount.int
  while lo < hi:
    let mid = (lo + hi) shr 1
    let c = intAt(pg, mid)
    if cmpBytes(probe, sepOpen(c)) < 0: hi = mid
    else: lo = mid + 1
  lo

proc leafLowerBound[A](s: Snapshot[A]; pg: Page;
                       probe: openArray[byte]): (int, bool) =
  ## (first index with element >= probe, exact match?)
  var lo = 0
  var hi = hdr(pg).cellCount.int
  while lo < hi:
    let mid = (lo + hi) shr 1
    if s.cmpProbeCell(probe, leafAt(pg, mid)) <= 0: hi = mid
    else: lo = mid + 1
  let exact = lo < hdr(pg).cellCount.int and
              s.cmpProbeCell(probe, leafAt(pg, lo)) == 0
  (lo, exact)

# -------------------------------------------------------------------------
# Cell construction
# -------------------------------------------------------------------------

proc buildLeafBlob[A](db: Db[A]; elem: openArray[byte]): seq[byte] =
  ## Serialize an element into leaf-cell bytes, packing the tail past
  ## MaxLocal into the txn's arena (byte-exact; see tailWrite).
  let inl = min(elem.len, MaxLocal)
  var tailPg = PageN(0)
  var tailOff = 0'u16
  if elem.len > MaxLocal:
    (tailPg, tailOff) = db.tailWrite(elem.toOpenArray(MaxLocal, elem.len - 1))
  result = newSeq[byte](LeafFixed + inl)
  let c = cast[ptr LeafObj](addr result[0])
  c.tailPg = tailPg
  c.tailOff = tailOff
  c.len = uint32(elem.len)
  if inl > 0:
    copyMem(addr c.data[0], unsafeAddr elem[0], inl)

proc buildIntBlob(child: PageN; sep: openArray[byte]): seq[byte] =
  result = newSeq[byte](IntFixed + sep.len)
  let c = cast[ptr InteriorObj](addr result[0])
  c.child = child
  c.sepLen = uint16(sep.len)
  if sep.len > 0:
    copyMem(addr c.sep[0], unsafeAddr sep[0], sep.len)

# -------------------------------------------------------------------------
# Separators
# -------------------------------------------------------------------------

proc sepBetween(left, right: openArray[byte]): seq[byte] =
  ## Shortest discriminating prefix: the smallest byte string s with
  ## left < s <= right, computed as right's prefix through its first
  ## byte that differs from left (or one past left's end if left is a
  ## byte-prefix of right — possible for probes, impossible for CE
  ## elements, handled anyway). Shorter separators ⇒ fatter interior
  ## fanout ⇒ shallower tree; this is where memcmp-ordered encodings
  ## collect their winnings.
  var i = 0
  while i < left.len and i < right.len and left[i] == right[i]:
    inc i
  doAssert i < right.len, "sepBetween: left does not sort before right"
  result = newSeq[byte](i + 1)
  copyMem(addr result[0], unsafeAddr right[0], i + 1)
  doAssert result.len <= MaxSep,
    "adjacent elements share a prefix longer than MaxSep (documented limit)"

# -------------------------------------------------------------------------
# Splits
#
# All splits rebuild pages from a SNAPSHOT of the page being split: the
# page is rebuilt in place, so cells must be read from somewhere stable.
# The snapshot is a raw copy by assignment — one linear PageSize memcpy,
# zero heap allocation (this replaced a per-cell seq[seq[byte]]
# materialization) — addressed through the ordinary page lenses. Tail
# pointers ride along inside the cell bytes, so packed tails survive the
# move untouched. The left half reuses the (already dirty) page; the
# right half is fresh. Split point balances BYTES, not cell counts,
# since cells vary in size.
# -------------------------------------------------------------------------

proc splitLeaf[A](db: Db[A]; pg: Page; idx: int; newBlob: seq[byte];
                  append: bool): (seq[byte], PageN) =
  var saved = pg[]                   # snapshot by assignment
  let sp = cast[Page](addr saved)
  let n = hdr(sp).cellCount.int + 1  # logical cells incl. newBlob
  # cell(j)/cellSize(j) address the LOGICAL cell list — the snapshot's
  # cells with newBlob spliced in at idx. Random access is free (the
  # snapshot keeps its slot array); the separator step relies on it.
  template cell(j: int): ptr LeafObj =
    (if j == idx: cast[ptr LeafObj](unsafeAddr newBlob[0])
     else: leafAt(sp, (if j < idx: j else: j - 1)))
  template cellSize(j: int): int =
    (if j == idx: newBlob.len else: leafCellSize(cell(j)))
  template addCell(dst: Page; at, j: int) =
    addBlob(dst, at, toOpenArray(cast[ptr UncheckedArray[byte]](cell(j)),
                                 0, cellSize(j) - 1))
  var m: int
  if append:
    # Append-optimized split (LMDB's MDB_APPEND / SQLite's balance_quick):
    # the insert is at the END of the RIGHTMOST leaf, i.e. a canonical-
    # order load. A balanced split would halve this leaf and the left
    # half would never see another insert — measured 49% fill for
    # ordered loads vs 65-69% for random. Instead: keep the old leaf
    # untouched (full) and start a fresh right page with just the new
    # element. Ordered loads then pack near-100%.
    m = n - 1
  else:
    var total = 0
    for j in 0 ..< n: total += cellSize(j) + 2
    m = 0
    var acc = 0
    while m < n - 1:
      acc += cellSize(m) + 2
      inc m
      if acc * 2 >= total: break
  # 1 <= m <= n-1: both halves nonempty.
  initPage(pg, pkLeaf)
  for j in 0 ..< m: addCell(pg, j, j)
  let (rp, rpg) = db.allocPage()
  initPage(rpg, pkLeaf)
  for j in m ..< n: addCell(rpg, j - m, j)
  # Separator discriminates the boundary pair. Requires the real element
  # bytes (chain included) since the discriminating byte could in theory
  # lie past the inline prefix.
  let le = db.rsnap.readElem(cell(m - 1))
  let re = db.rsnap.readElem(cell(m))
  (sepBetween(le, re), rp)

proc splitInterior[A](db: Db[A]; pg: Page; idx: int; newBlob: seq[byte];
                      append: bool): (seq[byte], PageN) =
  ## Interior split PROMOTES the middle separator (moves it up — unlike
  ## a leaf split, which copies a boundary key up). The promoted cell's
  ## child becomes the left half's rightChild. In the append case the
  ## halving pathology exists here too (ordered loads would leave every
  ## interior node half-full, halving fanout), so promote the freshly
  ## appended cell: left keeps all old cells, right starts as a bare
  ## rightChild and fills as the load continues.
  var saved = pg[]                   # snapshot by assignment
  let sp = cast[Page](addr saved)
  let n = hdr(sp).cellCount.int + 1  # logical cells incl. newBlob
  let savedRight = hdr(sp).rightChild
  template cell(j: int): ptr InteriorObj =
    (if j == idx: cast[ptr InteriorObj](unsafeAddr newBlob[0])
     else: intAt(sp, (if j < idx: j else: j - 1)))
  template cellSize(j: int): int =
    (if j == idx: newBlob.len else: intCellSize(cell(j)))
  template addCell(dst: Page; at, j: int) =
    addBlob(dst, at, toOpenArray(cast[ptr UncheckedArray[byte]](cell(j)),
                                 0, cellSize(j) - 1))
  let m = if append: n - 1
          else: n div 2              # n >= 2 => m >= 1
  let pc = cell(m)
  var sep = newSeq[byte](pc.sepLen.int)
  copyMem(addr sep[0], addr pc.sep[0], sep.len)
  let promotedChild = pc.child
  initPage(pg, pkInterior)
  for j in 0 ..< m: addCell(pg, j, j)
  hdr(pg).rightChild = promotedChild
  let (rp, rpg) = db.allocPage()
  initPage(rpg, pkInterior)
  for j in m + 1 ..< n: addCell(rpg, j - (m + 1), j)
  hdr(rpg).rightChild = savedRight
  (sep, rp)

# -------------------------------------------------------------------------
# Insert
# -------------------------------------------------------------------------

type
  InsertRes = object
    pgno: PageN                     # this subtree's (possibly new) page
    inserted: bool                  # false ⇒ element already present
    didSplit: bool
    sep: seq[byte]                  # valid iff didSplit
    right: PageN                    # valid iff didSplit

proc insertRec[A](db: Db[A]; pgno: PageN; elem: openArray[byte];
                  rightEdge: bool): InsertRes =
  ## rightEdge: true iff this subtree is on the tree's right spine (we
  ## took rightChild at every ancestor). Combined with an insert
  ## position at the END of the page, it identifies a canonical-order
  ## append, which splits unbalanced (see splitLeaf). The edge check
  ## matters: an end-of-page insert in a MID-tree leaf just means the
  ## key fell below a separator; splitting that unbalanced would strand
  ## a near-empty page that may never fill.
  let pg0 = db.getPage(pgno)
  case hdr(pg0).kind
  of pkLeaf:
    let (idx, exact) = db.rsnap.leafLowerBound(pg0, elem)
    if exact:
      # Duplicate: return with ZERO dirtying — the monotone no-op.
      # insert-if-absent and membership are literally the same descent.
      return InsertRes(pgno: pgno, inserted: false)
    let append = rightEdge and idx == hdr(pg0).cellCount.int
    let (np, pg) = db.dirtyCopy(pgno)
    let blob = db.buildLeafBlob(elem)
    if freeSpace(pg) >= blob.len + 2:
      addBlob(pg, idx, blob)
      InsertRes(pgno: np, inserted: true)
    else:
      let (sep, right) = db.splitLeaf(pg, idx, blob, append)
      InsertRes(pgno: np, inserted: true, didSplit: true,
                sep: sep, right: right)
  of pkInterior:
    let i = intDescendIdx(pg0, elem)
    let n0 = hdr(pg0).cellCount.int
    let childP = getChildAt(pg0, i)
    let res = db.insertRec(childP, elem, rightEdge and i == n0)
    if not res.inserted:
      # Nothing changed below: propagate the no-op untouched.
      return InsertRes(pgno: pgno, inserted: false)
    let (np, pg) = db.dirtyCopy(pgno)
    if not res.didSplit:
      # Child was rewritten (or was already dirty): re-point it. This is
      # the "dirtying a leaf dirties its whole root path" step.
      setChildAt(pg, i, res.pgno)
      return InsertRes(pgno: np, inserted: true)
    # Child i split into (left=res.pgno, sep, right=res.right).
    # Old slot i keeps its separator but its child becomes the RIGHT
    # half (right's elements still sort below sep_i); a new cell
    # (left, sep) is inserted AT i. Separator order stays strictly
    # ascending — see the invariant on InteriorObj.
    setChildAt(pg, i, res.right)
    let blob = buildIntBlob(res.pgno, res.sep)
    if freeSpace(pg) >= blob.len + 2:
      addBlob(pg, i, blob)
      InsertRes(pgno: np, inserted: true)
    else:
      let appendI = rightEdge and i == n0
      let (sep, right) = db.splitInterior(pg, i, blob, appendI)
      InsertRes(pgno: np, inserted: true, didSplit: true,
                sep: sep, right: right)
  else:
    doAssert false, "tree descent hit page kind " & $hdr(pg0).kind
    InsertRes()

proc insert*[A](db: Db[A]; elem: openArray[byte]): bool =
  ## Insert-if-absent. Returns true iff the element was new.
  doAssert db.inTxn, "insert requires an open transaction"
  doAssert elem.len < int(high(uint32)),
    "element exceeds the uint32 storage cap"
  if db.workRoot == 0:
    let (np, pg) = db.allocPage()
    initPage(pg, pkLeaf)
    addBlob(pg, 0, db.buildLeafBlob(elem))
    db.workRoot = np
    return true
  let res = db.insertRec(db.workRoot, elem, rightEdge = true)
  if res.inserted:
    db.workRoot = res.pgno
  if res.didSplit:
    # Root split, COW style: no page-number-preserving evacuation dance
    # (that trick exists to keep an in-place root's identity stable, and
    # here the root's identity changes every commit anyway — the meta
    # header absorbs it). Just build the new one-cell root above the two
    # halves. This is the only way the tree grows TALLER; all leaves
    # deepen by one simultaneously, preserving balance by construction.
    let (np, pg) = db.allocPage()
    initPage(pg, pkInterior)
    addBlob(pg, 0, buildIntBlob(res.pgno, res.sep))
    hdr(pg).rightChild = res.right
    db.workRoot = np
  res.inserted

# -------------------------------------------------------------------------
# Membership
# -------------------------------------------------------------------------

proc member*[A](s: Snapshot[A]; elem: openArray[byte]): bool =
  ## Pure descent over an immutable view: thread-safe, lock-free.
  var pgno = s.root
  if pgno == 0: return false
  while true:
    let pg = s.getPage(pgno)
    case hdr(pg).kind
    of pkInterior:
      pgno = getChildAt(pg, intDescendIdx(pg, elem))
    of pkLeaf:
      let (_, exact) = s.leafLowerBound(pg, elem)
      return exact
    else:
      doAssert false, "tree descent hit page kind " & $hdr(pg).kind

proc member*[A](db: Db[A]; elem: openArray[byte]): bool =
  db.rsnap.member(elem)

proc prefault*(s: Snapshot[MmapArena]; pgno: PageN) =
  ## mmap-backend extra (see mmaparena.prefault). MemArena pages are
  ## always resident, so nothing analogous exists there.
  prefault(s.backend, pgno)

proc memberPrefetching*(s: Snapshot[MmapArena]; elem: openArray[byte]): bool =
  ## Cold-optimized membership: identical descent to member, but every
  ## page is prefaulted via pread before the mapping touches it. Use for
  ## scattered lookups over a working set larger than RAM; for warm data
  ## plain member is faster (prefault costs a syscall + 16K copy).
  ## Limitation: tail arena pages are NOT prefaulted -- comparisons
  ## that tie through the whole inline prefix (>MaxLocal shared bytes)
  ## fault them cold. CE elements discriminate early; if a workload
  ## ever violates that, prefault inside cmpProbeCell's tail walk.
  var pgno = s.root
  if pgno == 0: return false
  while true:
    s.prefault(pgno)
    let pg = s.getPage(pgno)
    case hdr(pg).kind
    of pkInterior:
      pgno = getChildAt(pg, intDescendIdx(pg, elem))
    of pkLeaf:
      let (_, exact) = s.leafLowerBound(pg, elem)
      return exact
    else:
      doAssert false, "tree descent hit page kind " & $hdr(pg).kind

# -------------------------------------------------------------------------
# Cursor / prefix scan
#
# No sibling links (deliberate — smaller write sets per split, exactly
# the SQLite argument, which COW sharpens: a right-sibling pointer would
# force rewriting the left neighbor on every split, dirtying an entire
# extra path). The cursor keeps the root-to-leaf path and climbs to the
# parent to reach the next leaf.
#
# Cursors read a consistent tree: outside a txn, the committed root;
# inside, the work-in-progress root (and are invalidated by further
# inserts in that txn).
# -------------------------------------------------------------------------

type
  CFrame = tuple[pgno: PageN, idx: int]
  Cursor*[A] = object
    snap: Snapshot[A]
    prefix: seq[byte]
    stack: seq[CFrame]              # interior frames: idx = child taken
                                    # (0..cellCount); leaf frame on top
    valid: bool

proc settle[A](c: var Cursor[A]) =
  ## Establish the cursor on a real element at/after its position, or
  ## invalidate. Handles leaf exhaustion by climbing to the nearest
  ## ancestor with an untaken child and descending its leftmost spine.
  while true:
    if c.stack.len == 0:
      c.valid = false
      return
    let top = c.stack[^1]
    let pg = c.snap.getPage(top.pgno)
    if hdr(pg).kind == pkLeaf and top.idx < hdr(pg).cellCount.int:
      c.valid = c.prefix.len == 0 or
                c.snap.elemHasPrefix(leafAt(pg, top.idx), c.prefix)
      # Past the end of a prefix run means done for good: the run is
      # contiguous (any element sorting after the run's start without
      # the prefix sorts after every extension of the prefix).
      return
    c.stack.setLen(c.stack.len - 1)   # drop exhausted leaf
    while c.stack.len > 0:
      let ppg = c.snap.getPage(c.stack[^1].pgno)
      if c.stack[^1].idx < hdr(ppg).cellCount.int:
        inc c.stack[^1].idx
        var ch = getChildAt(ppg, c.stack[^1].idx)
        while true:                   # leftmost spine of next subtree
          let cp = c.snap.getPage(ch)
          c.stack.add((ch, 0))
          if hdr(cp).kind == pkLeaf: break
          ch = getChildAt(cp, 0)
        break
      c.stack.setLen(c.stack.len - 1)
    if c.stack.len == 0:
      c.valid = false
      return
    # loop: re-examine the freshly entered leaf

proc seekTo[A](c: var Cursor[A]; probe: openArray[byte]) =
  ## Descend to the lower bound of `probe`. For a prefix probe, shorter-
  ## first ordering makes the bare prefix <= every element extending it,
  ## so this lands at the start of the family's contiguous run; for a
  ## full key it lands at the first element >= that key.
  c.stack.setLen(0)
  c.valid = false
  var pgno = c.snap.root
  if pgno == 0: return
  while true:
    let pg = c.snap.getPage(pgno)
    case hdr(pg).kind
    of pkInterior:
      let i = intDescendIdx(pg, probe)
      c.stack.add((pgno, i))
      pgno = getChildAt(pg, i)
    of pkLeaf:
      let (idx, _) = c.snap.leafLowerBound(pg, probe)
      c.stack.add((pgno, idx))
      break
    else:
      doAssert false, "tree descent hit page kind " & $hdr(pg).kind
  c.settle()

proc current*[A](c: Cursor[A]): seq[byte] =
  ## Materializes a copy — always valid, chains included.
  doAssert c.valid
  let top = c.stack[^1]
  c.snap.readElem(leafAt(c.snap.getPage(top.pgno), top.idx))

proc currentIsInline*[A](c: Cursor[A]): bool =
  ## True iff the element lives contiguously in its page (no packed
  ## tail), i.e. currentSpan is available.
  doAssert c.valid
  let top = c.stack[^1]
  leafAt(c.snap.getPage(top.pgno), top.idx).tailPg == 0

proc currentSpan*[A](c: Cursor[A]): tuple[data: ptr UncheckedArray[byte],
                                          len: int] =
  ## Zero-copy borrow of the element's CE bytes, straight out of the
  ## backend. The backend's address stability guarantee makes the
  ## lifetime story honest: for a cursor over COMMITTED state the span
  ## is valid until close() (and on the mmap backend mprotect makes it
  ## mutation-proof); for a cursor inside a txn it is valid only until
  ## the next insert (same rule as the cursor itself). Only fully-inline
  ## elements are contiguous — check currentIsInline, or use current()
  ## which always works.
  doAssert c.valid
  let top = c.stack[^1]
  let cell = leafAt(c.snap.getPage(top.pgno), top.idx)
  doAssert cell.tailPg == 0, "tailed element has no contiguous span"
  (cast[ptr UncheckedArray[byte]](addr cell.data[0]), cell.len.int)

proc advance*[A](c: var Cursor[A]) =
  doAssert c.valid
  inc c.stack[^1].idx
  c.settle()

proc newCursor*[A](s: Snapshot[A]; prefix: openArray[byte]): Cursor[A] =
  result = Cursor[A](snap: s, prefix: @prefix)
  result.seekTo(prefix)

proc newCursor*[A](db: Db[A]; prefix: openArray[byte]): Cursor[A] =
  ## Binds the LIVE view: inside a txn the cursor sees uncommitted
  ## inserts (and is invalidated by further ones); use db.snapshot()
  ## and the Snapshot overloads for stable/parallel iteration.
  newCursor(db.rsnap, prefix)

proc newCursorAt*[A](s: Snapshot[A]; startKey: openArray[byte]): Cursor[A] =
  ## Positioned at the first element >= startKey, with NO prefix filter:
  ## iteration runs to the end of the set unless the caller bounds it
  ## (see scanRange).
  result = Cursor[A](snap: s, prefix: @[])
  result.seekTo(startKey)

proc isValid*[A](c: Cursor[A]): bool = c.valid

iterator scan*[A](s: Snapshot[A]; prefix: openArray[byte]): seq[byte] =
  ## The third and last operation: enumerate the contiguous run of
  ## elements extending `prefix`, in canonical order. Empty prefix
  ## enumerates the whole set.
  var c = s.newCursor(prefix)
  while c.valid:
    yield c.current()
    c.advance()

iterator scan*[A](s: Snapshot[A]): seq[byte] =
  var c = s.newCursor([])
  while c.valid:
    yield c.current()
    c.advance()

iterator scan*[A](db: Db[A]; prefix: openArray[byte]): seq[byte] =
  var c = db.newCursor(prefix)
  while c.valid:
    yield c.current()
    c.advance()

iterator scan*[A](db: Db[A]): seq[byte] =
  var c = db.newCursor([])
  while c.valid:
    yield c.current()
    c.advance()

proc pastEnd[A](c: Cursor[A]; endKey: openArray[byte]): bool =
  ## True when the cursor's element is >= endKey (zero-copy check
  ## against the cell, chains included). Empty endKey = unbounded.
  if endKey.len == 0: return false
  let top = c.stack[^1]
  let cell = leafAt(c.snap.getPage(top.pgno), top.idx)
  c.snap.cmpProbeCell(endKey, cell) <= 0

iterator scanRange*[A](s: Snapshot[A];
                       startKey, endKey: openArray[byte]): seq[byte] =
  ## Elements e with startKey <= e < endKey, canonical order. Empty
  ## endKey means unbounded. Together with partitionPoints this is the
  ## substrate for sharded parallel scans.
  var c = s.newCursorAt(startKey)
  while c.valid and not c.pastEnd(endKey):
    yield c.current()
    c.advance()

proc rangeStats*[A](s: Snapshot[A]; startKey, endKey: openArray[byte]):
    tuple[count: int, bytes: int64] =
  ## Count and total element bytes in [startKey, endKey) WITHOUT
  ## materializing anything -- reads only cell headers. This is the
  ## fast path for parallel aggregation.
  var c = s.newCursorAt(startKey)
  while c.valid and not c.pastEnd(endKey):
    let top = c.stack[^1]
    inc result.count
    result.bytes += int64(leafAt(c.snap.getPage(top.pgno), top.idx).len)
    c.advance()

proc gatherSeps[A](s: Snapshot[A]; pgno: PageN; depth: int;
                   acc: var seq[seq[byte]]) =
  ## In-order separator harvest down to `depth` interior levels. The
  ## recursion order (child, sep, child, sep, ...) yields boundaries
  ## already sorted; ancestors' separators interleave correctly because
  ## they ARE the boundaries between their children's ranges.
  let pg = s.getPage(pgno)
  if hdr(pg).kind != pkInterior: return
  let n = hdr(pg).cellCount.int
  for i in 0 .. n:
    if depth > 1:
      s.gatherSeps(getChildAt(pg, i), depth - 1, acc)
    if i < n:
      let c = intAt(pg, i)
      var sep = newSeq[byte](c.sepLen.int)
      if sep.len > 0: copyMem(addr sep[0], addr c.sep[0], sep.len)
      acc.add sep

proc partitionPoints*[A](s: Snapshot[A]; minParts = 0): seq[seq[byte]] =
  ## Shard boundaries whose subtree weights the tree itself keeps
  ## balanced. k separators partition the keyspace into k+1 scanRange
  ## shards.
  ##
  ## By default this is the root's separators — but a shallow fat tree
  ## can have very few root children (a 1M-element 32B tree has ~4),
  ## which starves a wide pool. minParts descends additional levels
  ## until at least that many shards exist (or leaves are reached, at
  ## which point every leaf is its own shard and that is the maximum).
  if s.root == 0: return
  var depth = 1
  while true:
    result.setLen(0)
    s.gatherSeps(s.root, depth, result)
    if minParts <= 0 or result.len + 1 >= minParts:
      break
    # deeper than the tree is pointless: gatherSeps stops at leaves, so
    # a depth increase that adds nothing means we are already maximal.
    var again = newSeq[seq[byte]]()
    s.gatherSeps(s.root, depth + 1, again)
    if again.len == result.len: break
    inc depth
  # Level granularity is coarse (each level multiplies boundary count by
  # the fanout, ~1500), so the first level to satisfy minParts usually
  # overshoots it wildly. Stride-subsample down: keeping every k-th
  # boundary keeps subtree COUNTS equal between kept boundaries, which
  # approximates the weight balance the tree maintains.
  if minParts > 0 and result.len + 1 > minParts * 2:
    let stride = (result.len + 1) div minParts
    var thinned = newSeq[seq[byte]]()
    var i = stride - 1
    while i < result.len:
      thinned.add result[i]
      i += stride
    result = thinned

# -------------------------------------------------------------------------
# Transactions and the commit protocol
#
# The crash-safety argument (durable backends; for MemArena every hook
# is a no-op and commit degenerates to adopting the new root):
#   1. dirty pages land only past the published high-water mark, so
#      nothing any committed root references is ever overwritten — which
#      is ALSO why early write-back of dirty pages is harmless by
#      construction (no durable root references them). The only ordering
#      that matters is pages-before-header, and that is exactly the
#      publish+barrier sequence below.
#   2. publish the txn's page range; barrier.
#   3. build the commit header; publish it; barrier.
# A crash before 3 leaves unreferenced tail garbage; recovery is the
# backward header scan, and the next commit reallocates over the garbage
# because allocation restarts from the PUBLISHED pageCount. Commit ends
# by trimming the backend to exactly the published size, so on a clean
# shutdown the recovery scan's first probe is the header.
# -------------------------------------------------------------------------

proc begin*[A](db: Db[A]) =
  doAssert not db.inTxn, "nested transactions not supported"
  db.inTxn = true
  db.workRoot = db.root
  db.txnStart = db.pageCount
  db.nextPage = db.pageCount
  db.arenaPg = 0                    # each txn packs its own arena
  db.arenaUsed = 0

proc rollback*[A](db: Db[A]) =
  ## Abandon the txn: reset the cursor and trim the backend back. The
  ## written garbage needs no undo — it was never referenced. (Trimming
  ## also means a later re-extension of the same range reads zeros;
  ## allocPage zeroes regardless.)
  doAssert db.inTxn
  db.inTxn = false
  trim(db.backend, int64(db.pageCount))

proc commit*[A](db: Db[A]) =
  doAssert db.inTxn
  if db.nextPage == db.txnStart and db.workRoot == db.root:
    db.inTxn = false                # all no-ops: nothing to publish
    return
  # Pages durable BEFORE the header that references them.
  publish(db.backend, db.txnStart, int(db.nextPage - db.txnStart))
  barrier(db.backend)
  let (hpg, hp) = db.allocPage()
  var ch = CommitHeader(magic: ChMagic, version: FormatVersion,
                        txid: db.txid + 1, root: db.workRoot,
                        pageCount: hpg + 1)
  ch.digest = headerHash(ch)
  copyMem(hp, addr ch, sizeof(ch))
  publish(db.backend, hpg, 1)
  barrier(db.backend)
  # Adopt. Old committed pages superseded this txn are now garbage; old
  # commit headers remain in place — each is a durable historical root.
  db.root = db.workRoot
  db.pageCount = hpg + 1
  db.txid = ch.txid
  db.inTxn = false
  trim(db.backend, int64(db.pageCount))   # EOF = published, exactly
  seal(db.backend, db.pageCount)          # history becomes immutable

template withTx*(db: untyped, body: untyped) =
  if db.inTxn:
    body
  else:
    try:
      db.begin()
      body
      db.commit()
    except:
      db.rollback()
      raise

# -------------------------------------------------------------------------
# Create / open / close
# -------------------------------------------------------------------------

proc initDb*[A](backend: sink A): Db[A] =
  ## Fresh store on an empty backend: superblock at page 0 (written once,
  ## ever), initial commit header at page 1 publishing the empty tree.
  result = Db[A](backend: backend)
  ensure(result.backend, 2)
  var sb = Superblock(magic: SbMagic, version: FormatVersion,
                      pageSize: uint32(PageSize))
  copyMem(pageAt(result.backend, PageN(0)), addr sb, sizeof(sb))
  var ch = CommitHeader(magic: ChMagic, version: FormatVersion,
                        txid: 0, root: 0, pageCount: 2)
  ch.digest = headerHash(ch)
  copyMem(pageAt(result.backend, PageN(1)), addr ch, sizeof(ch))
  publish(result.backend, PageN(0), 2)
  barrier(result.backend)
  result.root = 0
  result.pageCount = 2
  result.txid = 0
  trim(result.backend, 2)           # EOF = published (ensure rounds up)
  seal(result.backend, result.pageCount)

proc openDb*[A](backend: sink A): Db[A] =
  ## Recovery = the backward scan: probe page boundaries from the
  ## backend's content end until a block validates (magic + version +
  ## digest + the pageCount==p+1 self-consistency check). Clean shutdown
  ## ⇒ first probe hits, because commit trimmed content to the header.
  ## Crash ⇒ a few probes skip the unpublished tail. Every valid header
  ## deeper in the file remains a readable historical root.
  result = Db[A](backend: backend)
  doAssert contentPages(result.backend) >= 2, "backend holds no store"
  let sb = cast[ptr Superblock](pageAt(result.backend, PageN(0)))
  doAssert sb.magic == SbMagic, "not a blstore file"
  doAssert sb.version == FormatVersion, "format version mismatch"
  doAssert sb.pageSize == uint32(PageSize),
    "file has pageSize " & $sb.pageSize & ", build has " & $PageSize
  var p = contentPages(result.backend) - 1
  var found = false
  while p >= 1:
    let ch = cast[ptr CommitHeader](pageAt(result.backend, PageN(p)))
    if
      ch.magic == ChMagic and
      ch.version == FormatVersion and
      ch.pageCount == PageN(p) + 1 and
      headerHash(ch[]) == ch.digest:
      result.root = ch.root
      result.pageCount = ch.pageCount
      result.txid = ch.txid
      found = true
      break
    dec p
  doAssert found, "no valid commit header (file corrupt or torn at birth)"
  trim(result.backend, int64(result.pageCount))  # drop unpublished tail
  seal(result.backend, result.pageCount)

proc createDb*(path: string; force = false): Db[MmapArena] =
  ## New durable store at `path`. Refuses to clobber unless forced.
  initDb(createMmapArena(path, force))

proc openDb*(path: string): Db[MmapArena] =
  openDb(openMmapArena(path))

proc createMemDb*(): Db[MemArena] =
  ## Fresh in-memory store: same tree, same page format, no OS — the
  ## durability hooks are no-ops and pages live in MemArena's chunks.
  ## See dump for turning one into a store file.
  initDb(initMemArena())

proc close*[A](db: Db[A]) =
  doAssert not db.inTxn, "close inside a transaction; commit or rollback"
  close(db.backend)

# -------------------------------------------------------------------------
# Introspection
# -------------------------------------------------------------------------

proc height*[A](db: Db[A]): int =
  ## 0 = empty. Grows only via root splits; with real page sizes and
  ## truncated separators, height 3 covers tens of millions of elements.
  var pgno = if db.inTxn: db.workRoot else: db.root
  if pgno == 0: return 0
  result = 1
  while true:
    let pg = db.getPage(pgno)
    if hdr(pg).kind == pkLeaf: return
    inc result
    pgno = getChildAt(pg, 0)

proc pages*[A](db: Db[A]): int = db.pageCount.int

proc dump*[A](db: Db[A]; path: string) =
  ## Write the published pages [0, pageCount) to `path`. Because the
  ## format is backend-independent, the result is a valid store file —
  ## this is the MemArena persistence door (openDb the dump with the
  ## mmap backend), and for a file-backed Db it is a raw copy,
  ## historical roots and COW garbage included (compact is the tight
  ## rewrite).
  doAssert not db.inTxn, "dump inside a transaction; commit or rollback"
  var f = open(path, fmWrite)
  defer: f.close()
  for p in 0 ..< int(db.pageCount):
    doAssert f.writeBuffer(pageAt(db.backend, PageN(p)), PageSize) == PageSize

proc compact*(srcPath, dstPath: string; batch = 50_000) =
  ## Offline compaction: an ordered bulk rewrite of the live set into a
  ## fresh file. Because the scan yields canonical order, every insert
  ## takes the append-split path, so the output packs leaves ~100% and
  ## tails byte-exact -- the result is within a few percent of the
  ## theoretical minimum size regardless of how much COW garbage the
  ## source accumulated. The source is untouched (historical roots and
  ## all); adopting the result is the caller's rename. Batched commits
  ## keep publish incremental; a crash mid-compaction just leaves a
  ## partial dstPath to delete and retry.
  var src = openDb(srcPath)
  src.advise(amSequential)          # streaming read: let readahead run
  let s = src.snapshot()
  var dst = createDb(dstPath, force = true)
  var n = 0
  begin dst
  for e in s.scan():
    discard dst.insert(e)
    inc n
    if n mod batch == 0:
      commit dst
      begin dst
  commit dst
  close dst
  close src

proc lastTxid*[A](db: Db[A]): uint64 = db.txid

# =========================================================================
# Self-test. Storage never interprets elements, so arbitrary byte strings
# stand in for CE values (CE additionally guarantees prefix-freedom, which
# the tree does not require). Run both geometries:
#   nim c -r --mm:orc store.nim              # 16K pages
#   nim c -r --mm:orc -d:PageSize=256 store.nim   # forces deep trees
# =========================================================================

when isMainModule:
  import std/[algorithm, sets, os]

  proc nextRand(r: var uint64): uint64 =
    r = r xor (r shl 13)
    r = r xor (r shr 7)
    r = r xor (r shl 17)
    r

  proc genElem(r: var uint64): seq[byte] =
    let n = nextRand(r)
    let roll = n mod 100
    let len =
      if roll < 88: int(1 + (n shr 8) mod 60)                  # small
      elif roll < 97: int(80 + (n shr 8) mod 400)              # medium
      else: int(MaxLocal + 50 + (n shr 8) mod 20000)           # chained
    result = newSeq[byte](len)
    var x = n or 1
    for i in 0 ..< len:
      x = x xor (x shl 13); x = x xor (x shr 7); x = x xor (x shl 17)
      result[i] = byte(x and 0xFF)

  proc toStr(b: seq[byte]): string =
    result = newString(b.len)
    if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

  proc sortedUnique(xs: seq[seq[byte]]): seq[seq[byte]] =
    result = xs
    result.sort(proc(a, b: seq[byte]): int = cmpBytes(a, b))
    var o = 0
    for i in 0 ..< result.len:
      if o == 0 or cmpBytes(result[o - 1], result[i]) != 0:
        result[o] = result[i]
        inc o
    result.setLen(o)

  let path = getTempDir() / "blstore_test.db"
  removeFile(path)

  echo "PageSize=", PageSize, " MaxLocal=", MaxLocal, " Commit Size=", sizeof(CommitHeader)

  # --- build a reference set and load it in two transactions ------------
  var r = 0x9E3779B97F4A7C15'u64
  var all: seq[seq[byte]]
  for _ in 0 ..< 4000: all.add genElem(r)
  all.add newSeq[byte](0)                     # empty element: sorts first
  # a family sharing a 3-byte prefix, for the prefix-scan test
  for i in 0 ..< 200:
    var e = @[byte 0x77, 0x01, 0x42]
    var x = uint64(i) * 2654435761'u64 + 1
    for _ in 0 ..< int(3 + x mod 40):
      x = x xor (x shl 13); x = x xor (x shr 7); x = x xor (x shl 17)
      e.add byte(x and 0xFF)
    all.add e

  var db = createDb(path)
  var seen = initHashSet[string]()
  let half = all.len div 2

  db.begin()
  for i in 0 ..< half:
    let novel = not seen.containsOrIncl(toStr(all[i]))
    doAssert db.insert(all[i]) == novel       # duplicate ⇒ false, no-op
  db.commit()

  db.begin()
  for i in half ..< all.len:
    let novel = not seen.containsOrIncl(toStr(all[i]))
    doAssert db.insert(all[i]) == novel
  # duplicates across the txn boundary are still refused
  doAssert not db.insert(all[0])
  db.commit()

  let reference = sortedUnique(all)
  echo "elements=", reference.len, " pages=", db.pages, " height=", db.height

  # --- membership -------------------------------------------------------
  for e in reference:
    doAssert db.member(e)
  var probe = @[byte 0xFE, 0xFD, 0xFC, 0xFB]
  doAssert not db.member(probe)
  doAssert not db.member(reference[0] & @[byte 0x00])  # extension absent

  # --- full enumeration equals the sorted unique reference --------------
  # (also smoke-tests the zero-copy span against the materialized copy)
  var got: seq[seq[byte]]
  var spanChecked = 0
  block:
    var c = db.newCursor([])
    while c.isValid:
      let e = c.current()
      if c.currentIsInline():
        let (p, n) = c.currentSpan()
        doAssert n == e.len
        doAssert n == 0 or equalMem(p, unsafeAddr e[0], n)
        inc spanChecked
      else:
        doAssert e.len > MaxLocal   # only chained elements lack spans
      got.add e
      c.advance()
  doAssert spanChecked > 0
  doAssert got.len == reference.len
  for i in 0 ..< got.len:
    doAssert cmpBytes(got[i], reference[i]) == 0
  echo "full scan ok (", spanChecked, " spans verified)"

  # --- prefix scan is exactly the contiguous family ---------------------
  let pfx = @[byte 0x77, 0x01, 0x42]
  var wantPfx: seq[seq[byte]]
  for e in reference:
    if e.len >= 3 and e[0] == 0x77 and e[1] == 0x01 and e[2] == 0x42:
      wantPfx.add e
  var gotPfx: seq[seq[byte]]
  for e in db.scan(pfx): gotPfx.add @e
  doAssert gotPfx.len == wantPfx.len
  for i in 0 ..< gotPfx.len:
    doAssert cmpBytes(gotPfx[i], wantPfx[i]) == 0
  echo "prefix scan ok (", gotPfx.len, " elements)"

  # --- rollback ---------------------------------------------------------
  var ghost = @[byte 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]
  db.begin()
  doAssert db.insert(ghost)
  doAssert db.member(ghost)                   # visible inside the txn
  db.rollback()
  doAssert not db.member(ghost)               # gone with the txn
  echo "rollback ok"

  # --- single-writer lock: a second open of a live store is refused -----
  # (flock conflicts between fds even in one process, so this exercises
  # the real cross-process guard; the reopen below proves close releases)
  block:
    var refused = false
    try:
      discard openDb(path)
    except AssertionDefect:
      refused = true
    doAssert refused, "second open of a locked store must be refused"
  echo "flock: concurrent open refused"

  # --- reopen: recovery finds the last header; state is intact ----------
  db.close()
  db = openDb(path)
  doAssert not db.member(ghost)
  got.setLen(0)
  for e in reference: doAssert db.member(e)
  for e in db.scan(): got.add e
  doAssert got.len == reference.len
  for i in 0 ..< got.len:
    doAssert cmpBytes(got[i], reference[i]) == 0
  echo "reopen ok (txid=", db.lastTxid, ")"

  # --- one more commit after reopen -------------------------------------
  db.begin()
  doAssert db.insert(ghost)
  db.commit()
  doAssert db.member(ghost)
  db.close()
  db = openDb(path)
  doAssert db.member(ghost)
  db.close()
  echo "post-reopen commit ok"

  # --- canonical-order load exercises the append-split path -------------
  # (with -d:PageSize=256 this forces append splits at BOTH levels)
  let path2 = getTempDir() / "blstore_seq_test.db"
  removeFile(path2)
  var sq = createDb(path2)
  var ordered: seq[seq[byte]]
  for i in 0 ..< 5000:
    var e = newSeq[byte](24)
    for j in 0 ..< 8: e[7 - j] = byte(uint64(i) shr (8 * j))
    var x = uint64(i) xor 0xABCD'u64
    for j in 8 ..< 24:
      x = x xor (x shl 13); x = x xor (x shr 7); x = x xor (x shl 17)
      e[j] = byte(x and 0xFF)
    ordered.add e
  for chunk in 0 ..< 10:
    sq.begin()
    for i in chunk * 500 ..< (chunk + 1) * 500:
      doAssert sq.insert(ordered[i])
    sq.commit()
  var oi = 0
  for e in sq.scan():
    doAssert cmpBytes(e, ordered[oi]) == 0
    inc oi
  doAssert oi == 5000
  for e in ordered: doAssert sq.member(e)
  # interleave: out-of-order inserts into the packed tree still work
  sq.begin()
  var mid = ordered[2500]
  mid.add byte(0x01)
  doAssert sq.insert(mid)
  doAssert not sq.insert(ordered[4999])
  sq.commit()
  doAssert sq.member(mid)
  echo "ordered load ok (height=", sq.height, ", pages=", sq.pages, ")"
  sq.close()
  removeFile(path2)

  # --- tail arena boundary corpus -------------------------------------
  # Every interesting tail length: 1 byte, exact ArenaCap multiples and
  # their +/-1 neighbors (page-spanning tails), plus mid sizes that
  # force several tails to SHARE arena pages, split across two txns so
  # cross-txn arena isolation is exercised too.
  let path3 = getTempDir() / "blstore_tail_test.db"
  removeFile(path3)
  var tdb = createDb(path3)
  var tailLens = @[1, 2, 37, 1000, ArenaCap - 1, ArenaCap, ArenaCap + 1,
                   2 * ArenaCap - 1, 2 * ArenaCap, 2 * ArenaCap + 1,
                   ArenaCap div 2, ArenaCap div 2, ArenaCap div 2,
                   ArenaCap div 3 + 5, ArenaCap div 3 + 5]
  var corpus: seq[seq[byte]]
  for i, tl in tailLens:
    var e = newSeq[byte](MaxLocal + tl)
    var x = uint64(i + 1) * 0x9E3779B97F4A7C15'u64
    for j in 0 ..< e.len:
      x = x xor (x shl 13); x = x xor (x shr 7); x = x xor (x shl 17)
      e[j] = byte(x and 0xFF)
    corpus.add e
  let halfC = corpus.len div 2
  tdb.begin()
  for i in 0 ..< halfC: doAssert tdb.insert(corpus[i])
  tdb.commit()
  tdb.begin()
  for i in halfC ..< corpus.len: doAssert tdb.insert(corpus[i])
  # in-txn visibility across a fresh arena
  doAssert tdb.member(corpus[^1])
  doAssert not tdb.insert(corpus[0])
  tdb.commit()
  for e in corpus:
    doAssert tdb.member(e)
    var probe = e
    probe[^1] = probe[^1] xor 0xFF          # differ in the LAST tail byte
    doAssert not tdb.member(probe)
    probe = e & @[byte 0x00]                # extension of a tailed elem
    doAssert not tdb.member(probe)
  var tsorted = corpus
  tsorted.sort(proc(a, b: seq[byte]): int = cmpBytes(a, b))
  var ti = 0
  for e in tdb.scan():
    doAssert cmpBytes(e, tsorted[ti]) == 0  # full-byte roundtrip incl tails
    inc ti
  doAssert ti == corpus.len
  # prefix reaching THROUGH the tail
  block:
    let e0 = tsorted[0]
    var pfx = e0[0 ..< MaxLocal + 2]        # prefix ends inside the tail
    var hitn = 0
    for e in tdb.scan(pfx): inc hitn
    doAssert hitn == 1
  tdb.close()
  tdb = openDb(path3)                       # tails survive recovery
  for e in corpus: doAssert tdb.member(e)
  tdb.close()
  removeFile(path3)
  echo "tail arena boundary corpus ok (", corpus.len, " elements)"

  # --- compaction: ordered rewrite preserves the set exactly ------------
  let cpath = getTempDir() / "blstore_compact_test.db"
  compact(path, cpath, batch = 1000)
  var cdb = openDb(cpath)
  var ci = 0
  # the live source set (reference + the post-reopen ghost element)
  var srcdb = openDb(path)
  var want: seq[seq[byte]]
  for e in srcdb.scan(): want.add @e
  srcdb.close()
  for e in cdb.scan():
    doAssert cmpBytes(e, want[ci]) == 0
    inc ci
  echo "compaction ok (", ci, " elements, ", cdb.pages, " pages)"
  cdb.close()
  removeFile(cpath)

  # --- MemArena backend: same tree, same bytes, no OS -------------------
  # Identical insert sequence with identical txn boundaries must produce
  # a byte-identical page image on both backends (allocation is fully
  # deterministic), and a dumped mem store must open as a file store.
  let diffPath = getTempDir() / "blstore_diff_test.db"
  removeFile(diffPath)
  block:
    var mdb = createMemDb()
    var fdb = createDb(diffPath)
    mdb.begin(); fdb.begin()
    for i in 0 ..< half:
      discard mdb.insert(all[i]); discard fdb.insert(all[i])
    mdb.commit(); fdb.commit()
    mdb.begin(); fdb.begin()
    for i in half ..< all.len:
      discard mdb.insert(all[i]); discard fdb.insert(all[i])
    mdb.commit(); fdb.commit()
    # the mem tree carries the full corpus, tails included
    for e in reference: doAssert mdb.member(e)
    var gi = 0
    for e in mdb.scan():
      doAssert cmpBytes(e, reference[gi]) == 0
      inc gi
    doAssert gi == reference.len
    # rollback isolation without any file underneath
    var g2 = @[byte 0xDE, 0xAD, 0xBE, 0xEF]
    mdb.begin()
    doAssert mdb.insert(g2)
    doAssert mdb.member(g2)
    mdb.rollback()
    doAssert not mdb.member(g2)
    # byte-identical page images across backends
    doAssert mdb.pages == fdb.pages
    doAssert mdb.lastTxid == fdb.lastTxid
    for p in 0 ..< mdb.pages:
      doAssert equalMem(pageAt(mdb.backend, PageN(p)),
                        pageAt(fdb.backend, PageN(p)), PageSize)
    echo "mem backend differential ok (", mdb.pages, " pages byte-identical)"
    # dump: a mem store IS a store file
    let dumpPath = getTempDir() / "blstore_dump_test.db"
    removeFile(dumpPath)
    mdb.dump(dumpPath)
    var rdb = openDb(dumpPath)
    doAssert rdb.lastTxid == mdb.lastTxid
    for e in reference: doAssert rdb.member(e)
    rdb.close()
    removeFile(dumpPath)
    echo "mem dump -> mmap open ok"
    mdb.close()
    fdb.close()
    removeFile(diffPath)

  echo "all tests passed"
