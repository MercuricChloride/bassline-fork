## blstore_par.nim
## =========================================================================
## Parallel operations over blstore, via malebolgia's structured
## concurrency. Everything here rides on one fact: a committed Snapshot
## is an immutable value (no ref, no destructor, committed pages
## immutable — MMU-enforced on the mmap backend, immortal chunks on the
## mem backend), so spawning read work over one requires no locks, no
## channels, no isolation ceremony — tasks receive the Snapshot by copy
## and raw pointers into caller-owned result buffers, which outlive the
## awaitAll scope by construction (structured concurrency's whole point).
##
## The division of labor:
##   * memberMany     — chunked parallel point lookups. Warm: scales with
##                      cores. Cold (working set > RAM): scales with SSD
##                      queue depth, which is the bigger win.
##   * parallelStats  — sharded aggregation; shards come from the root
##                      page's own separators (partitionPoints), so the
##                      tree's balancing IS the load balancing.
##   * validateMany   — the parallel half of a validate-then-insert
##                      ingest pipeline: per-element pure checks fan out,
##                      the tree walk stays serial where it belongs.
##
## Tuning: malebolgia's pool is -d:ThreadPoolSize=N (default 8, counts
## the main thread). For CPU-bound warm work, N = cores. For fault-bound
## cold work, N ABOVE core count is correct — blocked-in-page-fault
## threads cost nothing and each one keeps another read in the device
## queue. If the pool is saturated, spawn runs the task inline on the
## caller — annotations are safe to leave in place for small inputs.
## =========================================================================

import malebolgia
import ./store

# -------------------------------------------------------------------------
# Parallel membership
# -------------------------------------------------------------------------

proc memberChunk[A](s: Snapshot[A]; keys: ptr UncheckedArray[seq[byte]];
                    a, b: int; res: ptr UncheckedArray[bool]) =
  for i in a ..< b:
    res[i] = s.member(keys[i])

proc memberChunkP(s: Snapshot[MmapArena];
                  keys: ptr UncheckedArray[seq[byte]];
                  a, b: int; res: ptr UncheckedArray[bool]) =
  for i in a ..< b:
    res[i] = s.memberPrefetching(keys[i])

proc memberManyCold*(s: Snapshot[MmapArena]; keys: openArray[seq[byte]];
                     chunk = 16): seq[bool] =
  ## memberMany for the cold/>RAM regime: lookups go through pread-based
  ## prefaulting, which on macOS routes the I/O around the serialized
  ## fault path. Small chunks keep many reads in the device queue.
  result = newSeq[bool](keys.len)
  if keys.len == 0: return
  let kp = cast[ptr UncheckedArray[seq[byte]]](unsafeAddr keys[0])
  let rp = cast[ptr UncheckedArray[bool]](addr result[0])
  var m = createMaster()
  m.awaitAll:
    var i = 0
    while i < keys.len:
      let a = i
      let b = min(i + chunk, keys.len)
      m.spawn memberChunkP(s, kp, a, b, rp)
      i = b

proc memberMany*[A](s: Snapshot[A]; keys: openArray[seq[byte]];
                    chunk = 512): seq[bool] =
  ## Membership for a batch of keys. Chunked so each task carries enough
  ## work to amortize spawn cost (~1us): at 0.6us/warm-lookup, 512 keys
  ## is ~300us of work per task. For cold workloads smaller chunks give
  ## the device more concurrent faults — chunk=32..64 is better there.
  result = newSeq[bool](keys.len)
  if keys.len == 0: return
  let kp = cast[ptr UncheckedArray[seq[byte]]](unsafeAddr keys[0])
  let rp = cast[ptr UncheckedArray[bool]](addr result[0])
  var m = createMaster()
  m.awaitAll:
    var i = 0
    while i < keys.len:
      let a = i
      let b = min(i + chunk, keys.len)
      m.spawn memberChunk(s, kp, a, b, rp)
      i = b

# -------------------------------------------------------------------------
# Sharded aggregation
# -------------------------------------------------------------------------

type Shard = tuple[a, b: seq[byte]]

proc shards*[A](s: Snapshot[A]; minParts = 0): seq[Shard] =
  ## The keyspace cut at tree separators: k+1 ranges, each one subtree.
  ## Weight balance is inherited from the tree. minParts descends extra
  ## levels when the root alone is too coarse for the pool (see
  ## partitionPoints).
  let ps = s.partitionPoints(minParts)
  if ps.len == 0:
    return @[(newSeq[byte](0), newSeq[byte](0))]
  result.add (newSeq[byte](0), ps[0])
  for i in 1 ..< ps.len:
    result.add (ps[i - 1], ps[i])
  result.add (ps[^1], newSeq[byte](0))

proc statShard[A](s: Snapshot[A]; sh: ptr UncheckedArray[Shard]; i: int;
                  cnt: ptr UncheckedArray[int];
                  byt: ptr UncheckedArray[int64]) =
  let (c, b) = s.rangeStats(sh[i].a, sh[i].b)
  cnt[i] = c
  byt[i] = b

proc parallelStats*[A](s: Snapshot[A];
                       minParts = ThreadPoolSize * 4): tuple[count: int, bytes: int64] =
  ## Count + total bytes over the whole set, one task per shard. Default
  ## shard count is 4x the pool so work-stealing can even out weight
  ## variance. The template for any commutative fold: replace statShard
  ## with your per-shard aggregation.
  var sh = s.shards(minParts)
  var cnts = newSeq[int](sh.len)
  var byts = newSeq[int64](sh.len)
  let shp = cast[ptr UncheckedArray[Shard]](addr sh[0])
  let cp = cast[ptr UncheckedArray[int]](addr cnts[0])
  let bp = cast[ptr UncheckedArray[int64]](addr byts[0])
  var m = createMaster()
  m.awaitAll:
    for i in 0 ..< sh.len:
      m.spawn statShard(s, shp, i, cp, bp)
  for i in 0 ..< sh.len:
    result.count += cnts[i]
    result.bytes += byts[i]

# -------------------------------------------------------------------------
# Validate-then-insert pipeline (parallel half)
# -------------------------------------------------------------------------

proc checkElem(e: openArray[byte]): bool =
  ## STAND-IN for CE canonicality validation — deliberately does a full
  ## pass over the bytes with a little arithmetic, which is the cost
  ## shape of real validation (tag walking, length checking, order
  ## verification). Replace with blnim's validator.
  var h = 0xCBF29CE484222325'u64
  for b in e:
    h = (h xor uint64(b)) * 0x100000001B3'u64
  (h or 1'u64) != 0   # always true; the work is the point

proc validateChunk(keys: ptr UncheckedArray[seq[byte]]; a, b: int;
                   res: ptr UncheckedArray[bool]) =
  for i in a ..< b:
    res[i] = checkElem(keys[i])

proc validateMany*(keys: openArray[seq[byte]]; chunk = 256): seq[bool] =
  ## Fan validation out across the pool. Pure per-element work — the
  ## textbook malebolgia shape.
  result = newSeq[bool](keys.len)
  if keys.len == 0: return
  let kp = cast[ptr UncheckedArray[seq[byte]]](unsafeAddr keys[0])
  let rp = cast[ptr UncheckedArray[bool]](addr result[0])
  var m = createMaster()
  m.awaitAll:
    var i = 0
    while i < keys.len:
      let a = i
      let b = min(i + chunk, keys.len)
      m.spawn validateChunk(kp, a, b, rp)
      i = b

proc ingest*[A](db: Db[A]; batch: openArray[seq[byte]]): int =
  ## The pipeline: parallel validate, then serial insert of the valid
  ## elements inside one txn. Returns the number of NEW elements.
  ## The tree walk stays single-threaded — at 1.5M+ inserts/s serial it
  ## is not the bottleneck; validation and fsync are, and this
  ## parallelizes the former and amortizes the latter.
  let ok = validateMany(batch)
  db.begin()
  for i in 0 ..< batch.len:
    if ok[i] and db.insert(batch[i]):
      inc result
  db.commit()