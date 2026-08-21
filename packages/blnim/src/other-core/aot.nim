include pkg/prelude
import ./types
export types

const
  DepthLimit* = 64
  MaxPayload* = 16 * 1024 * 1024

type
  Id* = int
  Value* = object
    kind*: Kind
    mark*: bool
    offset*: int
    ## header start byte loc
    size*: uint32
    ## payload byte len for atoms
    len*: int
    ## immediate child count for frames

  Values*[I] = object
    buf*: ptr UaBytes
    len*: int
    height*: int
    values*: seq[Value]
    index*: I

# I'm doing this because i'm a bit paranoid
proc `=copy`[I](dest: var Values[I]; source: Values[I]) {.error.}

proc initValues*[I](buf: ptr UaBytes, buflen: int,
    initialSize: int = 16 * 1024): Values[I] =
  Values[I](buf: buf, len: buflen, values: newSeq[Value](initialSize))

func add*[I](vals: var Values[I], v: sink Value): Id =
  result = vals.height
  if result >= vals.values.len:
    vals.values.setLen(max(16, vals.values.len * 2))
  # do this last so we don't accidentally copy!
  vals.values[result] = v
  inc vals.height

func get*[I](vals: Values[I], id: Id): Value =
  vals.values[id]

func span(v: Value): tuple[start: int, size: int] {.inline.} =
  case v.kind
  of bNum..bBytes:
    let h = if v.size <= 6: 1 elif v.size <= 254: 2 else: 6
    (v.offset - h, h + int(v.size))
  else:
    (v.offset, int(v.size))

template payload*[I](vals: Values[I], id: Id): openArray[byte] =
  ## an atom's payload bytes
  let v = vals.values[id]
  reject v.kind notin ScalarKinds:
    "not a sized atom"
  vals.buf.toOpenArray(v.offset, v.offset + v.size.int - 1)

template bytes*[I](vals: Values[I], v: Value): openArray[byte] =
  let (start, len) = span v
  vals.buf.toOpenArray(start, start + len - 1)

template bytes*[I](vals: Values[I], id: Id): openArray[byte] =
  ## the full encoding bytes of a value
  bytes(vals, vals.values[id])

func cmpVals*[I](vals: Values[I], a, b: Value): int =
  cmpBytes(vals.bytes(a), vals.bytes(b))

func cmpVals*[I](vals: Values[I], a, b: Id): int =
  vals.cmpVals(vals.values[a], vals.values[b])

proc scan*[I](vals: Values[I]): int =
  ## scans the buf and seeds the store
  let
    p = vals.buf
    avail = vals.len

  var
    parents: array[DepthLimit, Id]
    counts: array[DepthLimit, int]
    depth, off: int

  while true:
    if off >= avail:
      reject depth > 0:
        "unexpected end of input inside a frame"
      return off
    let b = p[off]
    case b.tag
    of 0x1:
      reject b.lbits != 0:
        "null with nonzero length bits"
      discard vals.add Value(
          kind: bNil,
          mark: b.mark,
          size: 1,
          offset: off
        )
      inc counts[depth]
      inc off
    of 0x2..0x5:
      let l = b.lbits
      var
        val = Value(kind: b.kind, mark: b.mark)
        pstart = 1
        psize: uint32
      if l < 7:
        psize = uint32(l)
      else:
        reject avail - off < 2:
          "unexpected end of input inside a length"
        let m = p[off + 1]
        if m != 255:
          reject m < 7:
            "non minimal med size"
          psize = uint32(m)
          pstart = 2
        else:
          reject avail - off < 6:
            "unexpected end of input inside a length"
          psize = be32(p.toOpenArray(off + 2, off + 5))
          reject psize < 255:
            "non minimal large size"
          pstart = 6
      let stride = pstart + int(psize)
      reject avail - off - pstart < int(psize):
        "unexpected end of input inside a payload"
      val.offset = off + pstart
      val.size = psize
      discard vals.add val
      inc counts[depth]
      off += stride
    of 0x6..0x9:
      reject b.lbits != 0:
        "frame header with nonzero length bits"
      reject depth + 1 >= DepthLimit:
        "nesting past the depth limit"
      let frameId = vals.add Value(
        kind: b.kind,
        mark: b.mark,
        offset: off
      )
      inc counts[depth]
      inc depth
      inc off
      parents[depth] = frameId
      counts[depth] = 0
    of 0xA:
      reject b != EndByte:
        "END carries no mark and no length"
      reject depth == 0:
        "END where a value was expected"
      inc off
      let f = parents[depth]
      vals.values[f].size = uint32(off - vals.values[f].offset)
      vals.values[f].len = counts[depth]
      dec depth
    else:
      refuse "invalid tag"

# ================ relations ================

proc index*[I](vals: var Values[I]) =
  mixin prepare, observe
  let lo = vals.index.lastIndex
  if lo >= vals.height:
    return
  prepare(vals, lo)

  var
    stack: array[DepthLimit, tuple[id: Id, endB: int]]
    sp = 0
  for id in lo ..< vals.height:
    let v = vals.values[id]
    while sp > 0 and v.offset >= stack[sp - 1].endB:
      dec sp
    observe(vals, id, v, stack[sp - 1].id, sp)
    if v.kind in FrameKinds:
      stack[sp] = (id: id, endB: v.offset + int(v.size))
      inc sp
  vals.index.lastIndex = vals.height

type
  Bucket* = enum
    ixRoot, ixAtom, ixFrame, ixNum, ixText, ixRec, ixSet, ixDict

  FullIndex* = object
    lastIndex*: int
    parents*: seq[Id]
    kidStart*: seq[int]
    kidBuf*: seq[Id]
    buckets*: array[Bucket, seq[Id]]
    ## This feels so stupid, but according to benchmarks
    ## this is faster than named fields

const Route: array[Kind, tuple[group, law: Bucket, hasLaw: bool]] = [
  ## Again this feels stupid but its faster for varying kinds
  bInvalid: (ixAtom, ixAtom, false),
  bNil: (ixAtom, ixAtom, false),
  bNum: (ixAtom, ixNum, true),
  bStr: (ixAtom, ixText, true),
  bSym: (ixAtom, ixText, true),
  bBytes: (ixAtom, ixAtom, false),
  bList: (ixFrame, ixFrame, false),
  bRec: (ixFrame, ixRec, true),
  bDict: (ixFrame, ixDict, true),
  bSet: (ixFrame, ixSet, true),
]

template prepare*(vals: var Values[FullIndex], lo: int) =
  var bucketCur {.inject.}: array[Bucket, int]
  var kidCur {.inject.}: array[DepthLimit, int]
  block:
    template ix: untyped = vals.index
    if lo == 0:
      for b in Bucket:
        ix.buckets[b].setLen(0)

    ix.kidStart.setLen(vals.height + 1)
    var
      acc = if lo == 0: 0 else: ix.kidStart[lo]
      census: array[Kind, int]
    let accStart = acc
    for id in lo ..< vals.height:
      ix.kidStart[id] = acc
      acc += vals.values[id].len
      inc census[vals.values[id].kind]
    ix.kidStart[vals.height] = acc
    ix.kidBuf.setLen(acc)
    ix.parents.setLen(vals.height)

    var want: array[Bucket, int]
    want[ixRoot] = (vals.height - lo) - (acc - accStart)
    want[ixAtom] = census[bNil] + census[bNum] + census[bStr] +
      census[bSym] + census[bBytes]
    want[ixFrame] = census[bList] + census[bRec] + census[bDict] +
      census[bSet]
    want[ixNum] = census[bNum]
    want[ixText] = census[bStr] + census[bSym]
    want[ixRec] = census[bRec]
    want[ixSet] = census[bSet]
    want[ixDict] = census[bDict]

    for b in Bucket:
      bucketCur[b] = ix.buckets[b].len
      ix.buckets[b].setLen(bucketCur[b] + want[b])

template observe*(vals: var Values[FullIndex], id: Id, v: Value,
    parent: Id, depth: int) =
  block:
    template ix: untyped = vals.index
    template put(b: Bucket) =
      ix.buckets[b][bucketCur[b]] = id
      inc bucketCur[b]

    if depth > 0:
      ix.parents[id] = parent
      ix.kidBuf[kidCur[depth - 1]] = id
      inc kidCur[depth - 1]
    else:
      ix.parents[id] = -1
      put ixRoot
    let r = Route[v.kind]
    if r.hasLaw:
      put r.law
    put r.group
    if r.group == ixFrame:
      kidCur[depth] = ix.kidStart[id]

template bucket*(vals: Values[FullIndex], b: Bucket): openArray[Id] =
  ## a bucket's ids as a view; index() first
  vals.index.buckets[b].toOpenArray(0, vals.index.buckets[b].len - 1)

template roots*(vals: Values[FullIndex]): openArray[Id] =
  vals.bucket(ixRoot)

template kids*(vals: Values[FullIndex], id: Id): openArray[Id] =
  vals.index.kidBuf.toOpenArray(vals.index.kidStart[id],
    vals.index.kidStart[id + 1] - 1)

func parentOf*(vals: var Values[FullIndex], id: Id): Id =
  vals.index.parents[id]

type
  RootIndex* = object
    lastIndex*: int
    rootIds*: seq[Id]

template prepare*(vals: var Values[RootIndex], lo: int) =
  if lo == 0:
    vals.index.rootIds.setLen(0)

template observe*(vals: var Values[RootIndex], id: Id, v: Value,
    parent: Id, depth: int) =
  if depth == 0:
    vals.index.rootIds.add id

template roots*(vals: Values[RootIndex]): openArray[Id] =
  vals.index.rootIds.toOpenArray(0, vals.index.rootIds.len - 1)

proc validate*(vals: var Values[FullIndex]) =
  if vals.index.lastIndex < vals.height:
    vals.index()
  for id in vals.index.buckets[ixNum]:
    validateInt(vals.payload(id))
  for id in vals.index.buckets[ixText]:
    validateText(vals.payload(id))
  for id in vals.index.buckets[ixRec]:
    reject vals.values[id].len == 0:
      "record with no head"
  for id in vals.index.buckets[ixDict]:
    let
      count = vals.values[id].len
      ks = vals.index.kidStart[id]
    reject count mod 2 != 0:
      "dict with a key missing its value"
    var i = 2
    while i < count:
      reject vals.cmpVals(vals.index.kidBuf[ks + i - 2],
        vals.index.kidBuf[ks + i]) >= 0:
        "dict keys out of order or duplicated"
      i += 2
  for id in vals.index.buckets[ixSet]:
    let
      count = vals.values[id].len
      ks = vals.index.kidStart[id]
    for i in 1 ..< count:
      reject vals.cmpVals(vals.index.kidBuf[ks + i - 1],
        vals.index.kidBuf[ks + i]) >= 0:
        "set members out of order or duplicated"
