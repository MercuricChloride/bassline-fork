## memarena.nim
## =========================================================================
## The in-memory backend: no file, no OS paging — just a block arena.
##
## The mmap backend's trick is reserving ADDRESS SPACE once so page
## addresses never move; this replays it one level up, reserving a fixed
## chunk DIRECTORY once (MaxChunks pointers, 128KB at the defaults) and
## allocating GrowChunk-byte chunks on demand. Chunks never move and
## never die before close, so pageAt results have exactly the mmap
## backend's stability — zero-copy spans included — and a Snapshot stays
## a plain copyable value for parallel readers: directory entries
## covering pages below a snapshot's limit were written before the
## snapshot was taken, and readers never look past limit. Chunks come
## from allocShared0 so reader threads may touch them freely.
##
## All durability hooks (publish/barrier/trim/seal) are no-ops: commit
## degenerates to adopting the new root. The FORMAT is untouched —
## superblock and commit headers are laid down in memory exactly as on
## disk, so pages [0, pageCount) dumped to a file ARE a valid store file
## (see store.dump), and historical roots work in memory too.
##
## -d:ReservedGb=N (shared with the mmap backend) sizes the
## addressable space — directory capacity only; memory is allocated
## chunk by chunk as the tree grows.
## =========================================================================

import ./pages

const
  ChunkPages = GrowChunk div PageSize
  MaxChunks = (int(ReservedGb) shl 30) div GrowChunk
  ChunkShift = block:
    var s = 0
    var v = ChunkPages
    while v > 1:
      v = v shr 1
      inc s
    s

static:
  doAssert (ChunkPages and (ChunkPages - 1)) == 0

type
  MemArena* = object
    directory*: ptr UncheckedArray[pointer]   # fixed table, allocated
    chunks: int

proc initMemArena*(): MemArena =
  MemArena(directory: cast[ptr UncheckedArray[pointer]](
    allocShared0(MaxChunks * sizeof(pointer))))

template pageAt*(a: MemArena; pgno: PageN): Page =
  block:
    let pn = int(pgno)
    cast[Page](cast[uint](a.directory[pn shr ChunkShift]) +
               uint((pn and (ChunkPages - 1)) * PageSize))

proc ensure*(a: var MemArena; pages: int) =
  ## Allocate chunks until pages [0, pages) resolve. allocShared0 keeps
  ## the mmap invariant that fresh ranges read as zeros ("zeroed memory
  ## never decodes as a valid page").
  let need = (pages + ChunkPages - 1) div ChunkPages
  doAssert need <= MaxChunks,
    "arena outgrew the directory; rebuild with -d:ReservedGb=more"
  while a.chunks < need:
    a.directory[a.chunks] = allocShared0(GrowChunk)
    inc a.chunks

proc publish*(a: var MemArena; first: PageN; count: int) = discard
proc barrier*(a: var MemArena) = discard
proc trim*(a: var MemArena; pages: int64) = discard
proc seal*(a: var MemArena; limit: PageN) = discard

proc contentPages*(a: MemArena): int64 =
  ## Capacity, not published size — meaningful only for a future
  ## load-from-bytes door. A fresh arena reports 0, so openDb refuses
  ## it; a mem store starts life through initDb.
  int64(a.chunks) * ChunkPages

proc close*(a: var MemArena) =
  if a.directory == nil: return
  for i in 0 ..< a.chunks:
    deallocShared(a.directory[i])
  deallocShared(a.directory)
  a.directory = nil
  a.chunks = 0