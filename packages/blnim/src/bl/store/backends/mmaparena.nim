## mmaparena.nim
## =========================================================================
## The durable backend: one file under one fixed mmap reservation.
##
##   * One fixed mapping, reserved once. The file lives under a single
##     large virtual reservation (ReservedGb, default 64) created at
##     open; growth is a fallocate/ftruncate + pages simply becoming
##     valid under the existing map. NO remapping, ever — pageAt results
##     are stable for the process lifetime, which is what makes the
##     tree's zero-copy borrows honest. (This deliberately avoids
##     memfiles.resize, whose macOS path is munmap+mmap and moves the
##     base address.)
##   * EOF stays meaningful: trim cuts the file to exactly the published
##     size, so the backward recovery scan starts at truth.
##   * seal mprotects the committed prefix PROT_READ: the COW discipline
##     is MMU-enforced — a stray write through a committed-page pointer
##     is an immediate segfault, not silent file corruption. Rounded
##     DOWN to the OS page, so when PageSize is smaller than the OS page
##     the last partial OS page stays writable.
##   * publish (msync) ranges are rounded out to OS-page boundaries
##     (required by the syscall); the extra clean pages swept in are
##     harmless. msync is the write-back, not durability — barrier
##     provides the fence.
##   * Disk-full: growth reserves real blocks first (Linux:
##     posix_fallocate; macOS: our own F_PREALLOCATE call — Nim's stdlib
##     shim is buggy, see growTo), so a write into the mapping cannot
##     SIGBUS on ENOSPC; genuine disk-full errors at allocation time.
##     Filesystems without reservation support degrade to sparse growth.
##   * macOS: fsync alone does not force platter durability; barrier
##     attempts F_FULLFSYNC when compiled for macosx.
##   * Single writer per file, enforced: create/open take a non-blocking
##     exclusive flock held for the life of the fd, so a second process
##     opening the same store fails fast instead of silently corrupting
##     it. close releases the lock with the fd.
##
## -d:ReservedGb=N sizes the virtual reservation (address space only,
## no memory or disk cost).
## =========================================================================

import std/[posix, os]
import pages

const
  MapReserve = int(ReservedGb) shl 30

type
  MmapArena* = object
    map*: ptr UncheckedArray[byte]  # base of the fixed reservation.
                                    # Public only because pageAt is a
                                    # template; treat as backend-private.
    fd: cint
    fileSize: int64                 # current ftruncated size (bytes)

let osPage = sysconf(SC_PAGESIZE)   # msync/mprotect alignment granule

proc alignDown(x: int64): int64 = x - (x mod osPage)

when defined(macosx):
  # Our own F_PREALLOCATE binding. Nim's stdlib posix_fallocate shim for
  # macOS passes fst_offset = <current file size> together with
  # F_PEOFPOSMODE — but PEOF posmode makes the offset relative to the
  # physical END of file, so growing an existing file requests blocks
  # starting fileSize bytes past EOF and APFS rejects it with EINVAL
  # (create worked, first growth exploded). The correct form — SQLite's
  # unixAllocate form — is offset 0, length = delta.
  type FStoreT {.importc: "fstore_t", header: "<fcntl.h>".} = object
    fst_flags: uint32
    fst_posmode: cint
    fst_offset, fst_length, fst_bytesalloc: Off
  var F_PREALLOCATE {.importc, header: "<fcntl.h>".}: cint
  var F_ALLOCATEALL {.importc, header: "<fcntl.h>".}: uint32
  var F_PEOFPOSMODE {.importc, header: "<fcntl.h>".}: cint

# flock is not in std/posix; values come from the C header, not literals.
var
  LOCK_EX {.importc, header: "<sys/file.h>".}: cint
  LOCK_NB {.importc, header: "<sys/file.h>".}: cint
proc flock(fd: cint; op: cint): cint
  {.importc, header: "<sys/file.h>".}

proc growTo(a: var MmapArena; newSize: int64) =
  ## Grow the file to newSize: best-effort real block reservation first
  ## (kills SIGBUS-on-ENOSPC — genuine disk-full surfaces here as an
  ## error), then ftruncate to set the logical size. Reservation failure
  ## for any reason OTHER than ENOSPC (unsupported filesystem, etc.)
  ## degrades gracefully to sparse growth.
  let delta = newSize - a.fileSize
  doAssert delta > 0
  when defined(macosx):
    var fst = FStoreT(fst_flags: F_ALLOCATEALL, fst_posmode: F_PEOFPOSMODE,
                      fst_offset: 0, fst_length: Off(delta))
    if fcntl(a.fd, F_PREALLOCATE, addr fst) == -1:
      doAssert errno != ENOSPC, "disk full"
  else:
    let r = posix_fallocate(a.fd, Off(a.fileSize), Off(delta))
    doAssert r != ENOSPC, "disk full"
  doAssert ftruncate(a.fd, Off(newSize)) == 0,
    "ftruncate failed: " & $strerror(errno)
  a.fileSize = newSize

template pageAt*(a: MmapArena; pgno: PageN): Page =
  cast[Page](addr a.map[int(pgno) * PageSize])

proc ensure*(a: var MmapArena; pages: int) =
  ## Make pages [0, pages) touchable, growing in GrowChunk steps via
  ## growTo (real reservation where the fs supports it, sparse
  ## otherwise). Disk-full surfaces HERE, as an error, instead of as a
  ## SIGBUS on some later store into the mapping.
  let needed = int64(pages) * PageSize
  if needed <= a.fileSize: return
  var newSize = a.fileSize + GrowChunk
  while newSize < needed: newSize += GrowChunk
  doAssert newSize <= MapReserve,
    "file outgrew the virtual reservation; rebuild with -d:ReservedGb=more"
  a.growTo(newSize)

proc publish*(a: var MmapArena; first: PageN; count: int) =
  ## MS_SYNC the page range, rounded out to OS-page boundaries (the
  ## syscall demands an aligned address; the extra clean pages swept in
  ## are harmless). Write-back only — barrier provides durability.
  if count <= 0: return
  let offset = int64(first) * PageSize
  let s = alignDown(offset)
  let e = offset + int64(count) * PageSize
  doAssert msync(addr a.map[s], int(e - s), MS_SYNC) == 0, "msync failed"

proc barrier*(a: var MmapArena) =
  ## Durability fence on the raw fd. On macOS plain fsync only reaches
  ## the drive cache; F_FULLFSYNC (51) asks for the platter. Falls back
  ## to fsync where F_FULLFSYNC is unsupported (some network/ExFAT fs).
  when defined(macosx):
    const F_FULLFSYNC = 51
    if fcntl(a.fd, F_FULLFSYNC) != -1:
      return
  doAssert fsync(a.fd) == 0, "fsync failed"

proc trim*(a: var MmapArena; pages: int64) =
  ## Shrink the file to exactly `pages` pages, keeping EOF = the append
  ## frontier (this is what the recovery scan anchors on).
  let bytes = pages * PageSize
  if a.fileSize > bytes:
    doAssert ftruncate(a.fd, Off(bytes)) == 0, "ftruncate failed"
    a.fileSize = bytes

proc seal*(a: var MmapArena; limit: PageN) =
  ## MMU-enforce the COW discipline: everything below `limit` is
  ## PROT_READ. Rounded DOWN so partial OS pages (only possible when
  ## PageSize < osPage, i.e. test geometries) stay writable — the
  ## enforcement is belt-and-suspenders, not a correctness dependency.
  let bytes = alignDown(int64(limit) * PageSize)
  if bytes > 0:
    doAssert mprotect(a.map, int(bytes), PROT_READ) == 0, "mprotect failed"

proc contentPages*(a: MmapArena): int64 = a.fileSize div PageSize

type MapAdvice* = enum
  amNormal      ## default: kernel heuristics (moderate readahead)
  amRandom      ## scattered access: fault reads ONLY its own pages.
                ## On macOS this disables cluster/speculative pagein,
                ## which otherwise inflates every cold random fault to
                ## 128KB+ of mostly-wasted neighbor pages -- the
                ## difference between an IOPS ceiling and a bandwidth
                ## ceiling for cold point lookups.
  amSequential  ## streaming: aggressive readahead, evict-behind. Right
                ## for large cold scans and compaction passes.

proc madviseSys(a: pointer; len: csize_t; advice: cint): cint
  {.importc: "madvise", header: "<sys/mman.h>".}

proc advise*(a: MmapArena; adv: MapAdvice) =
  ## Hint the kernel's pagein policy for the mapping. Best-effort and
  ## switchable at any time: amRandom before cold point-lookup phases,
  ## amSequential before big cold scans, amNormal otherwise. Values
  ## (0,1,2) are identical on Linux and Darwin.
  const vals = [amNormal: cint(0), amRandom: cint(1), amSequential: cint(2)]
  # Whole reservation preferred (covers future growth); some kernels
  # reject advice past EOF, so fall back to the current file span.
  if madviseSys(a.map, csize_t(MapReserve), vals[adv]) != 0:
    discard madviseSys(a.map, csize_t(a.fileSize), vals[adv])

var prefaultBuf {.threadvar.}: pointer   # 16K scratch, one per thread,
                                         # lives for the thread's life

proc prefault*(a: MmapArena; pgno: PageN) =
  ## Pull a page through pread(2) into a throwaway buffer. The read is
  ## discarded; its side effect -- populating the kernel's unified page
  ## cache -- is the point. On macOS, concurrent pread scales across
  ## threads while concurrent page FAULTS on one mapping serialize in
  ## the per-vm-object pagein path (measured: flat ~30k faults/s from
  ## pool 10 through 32). After prefault, the ordinary mmap access is a
  ## soft fault against a resident page. Best-effort: a failed pread
  ## just means the normal fault path pays the I/O instead.
  if prefaultBuf == nil: prefaultBuf = alloc(PageSize)
  discard pread(a.fd, prefaultBuf, PageSize, Off(int64(pgno) * PageSize))

proc mapArena(a: var MmapArena) =
  ## The one and only mmap: the full reservation, shared+read/write.
  ## Everything past EOF is fault-on-touch until fallocate makes it
  ## real; the base address never changes after this call.
  let m = mmap(nil, MapReserve, PROT_READ or PROT_WRITE, MAP_SHARED,
               a.fd, Off(0))
  doAssert m != MAP_FAILED, "mmap reservation failed"
  a.map = cast[ptr UncheckedArray[byte]](m)

proc lockExclusive(fd: cint; path: string) =
  ## Advisory single-writer enforcement: an exclusive flock held for the
  ## life of the fd. Without it two processes both map the file and
  ## silently destroy it — both allocate from the same high-water mark
  ## and the last write-back wins. Non-blocking, so a second opener
  ## fails fast instead of queueing behind a long-lived writer. flock
  ## conflicts between fds even within one process, so accidental
  ## double-opens are caught too.
  if flock(fd, LOCK_EX or LOCK_NB) != 0:
    discard posix.close(fd)
    doAssert false, "store is locked by another process: " & path

proc createMmapArena*(path: string; force = false): MmapArena =
  ## New empty file + mapping. Refuses to clobber an existing file
  ## unless forced (the open is O_TRUNC: an accidental create on a real
  ## database would be irreversible).
  if fileExists(path):
    doAssert force, "File already exists, use force=true"
  let fd = posix.open(path.cstring, O_RDWR or O_CREAT or O_TRUNC,
                      Mode(0o644))
  doAssert fd >= 0, "cannot create " & path
  fd.lockExclusive(path)
  result = MmapArena(fd: fd)
  result.mapArena()

proc openMmapArena*(path: string): MmapArena =
  ## Existing file + mapping; content validation (superblock, recovery
  ## scan) is the tree's job, not the backend's.
  let fd = posix.open(path.cstring, O_RDWR)
  doAssert fd >= 0, "cannot open " & path
  fd.lockExclusive(path)
  result = MmapArena(fd: fd)
  var st: Stat
  doAssert fstat(fd, st) == 0
  result.fileSize = st.st_size
  doAssert result.fileSize <= MapReserve,
    "file exceeds the virtual reservation; rebuild with -d:ReservedGb=more"
  result.mapArena()

proc close*(a: var MmapArena) =
  doAssert munmap(a.map, MapReserve) == 0
  a.map = nil
  discard posix.close(a.fd)        # releases the flock with the fd
