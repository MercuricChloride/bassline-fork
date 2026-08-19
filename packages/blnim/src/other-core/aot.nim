include pkg/prelude
import ./validation

const
  EndByte = 0xA0'u8
  DepthLimit* = 64
  MaxPayload* = 16 * 1024 * 1024

type
  RefuseError* = object of CatchableError
  Kind* = enum
    bInvalid,
    bNil,
    bNum, bStr, bSym, bBytes
    bList, bRec, bDict, bSet
  Bucket* = enum
    ixRoot, ixAtom, ixFrame, ixNum, ixText, ixRec, ixSet, ixDict
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
  Values* = object
    buf*: ptr UncheckedArray[byte]
    buflen*: int
    height*: int
    values*: seq[Value]
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

template tua*(v: pointer): ptr UncheckedArray[byte] =
  cast[ptr UncheckedArray[byte]](v)

# header lenses
func tag*(b: byte): byte {.inline.} =
  (b and 0xF0) shr 4
func mark*(b: byte): bool {.inline.} =
  (b and 0x08) != 0
func lbits*(b: byte): byte {.inline.} =
  b and 0x07
func kind*(b: byte): Kind {.inline.} =
  Kind(b.tag)

func refuse*(msg: string) {.noreturn.} =
  raise newException(RefuseError, msg)

template reject*(cond, msg: untyped): untyped =
  if cond:
    refuse msg

proc initValues*(buf: ptr UncheckedArray[byte], buflen: int,
    initialSize: int = 16 * 1024): Values =
  Values(buf: buf, buflen: buflen, values: newSeq[Value](initialSize))

func add*(vals: var Values, v: sink Value): Id =
  result = vals.height
  if result >= vals.values.len:
    vals.values.setLen(max(16, vals.values.len * 2))
  # do this last so we don't accidentally copy!
  vals.values[result] = v
  inc vals.height

func get*(vals: var Values, id: Id): Value =
  vals.values[id]

# misc
func be32(p: ptr UncheckedArray[byte], i: int): uint32 {.inline.} =
  (uint32(p[i]) shl 24) or (uint32(p[i + 1]) shl 16) or
    (uint32(p[i + 2]) shl 8) or uint32(p[i + 3])

func span(v: Value): (int, int) {.inline.} =
  case v.kind
  of bNum..bBytes:
    let h = if v.size <= 6: 1 elif v.size <= 254: 2 else: 6
    (v.offset - h, h + int(v.size))
  else:
    (v.offset, int(v.size))

template payload*(vals: var Values, id: Id): openArray[byte] =
  ## an atom's payload bytes: the encoding minus its header
  let v = vals.values[id]
  reject v.kind notin {bNum..bBytes}:
    "not a sized atom"
  vals.buf.toOpenArray(v.offset, v.offset + v.size.int - 1)

func cmpVals*(vals: var Values, a, b: Value): int =
  let
    (astart, alen) = a.span
    (bstart, blen) = b.span
  result = cmpMem(addr(vals.buf[astart]), addr(vals.buf[bstart]),
    min(alen, blen))
  if result != 0: return
  result = cmp(alen, blen)

func cmpVals*(vals: var Values, a, b: Id): int =
  vals.cmpVals(vals.values[a], vals.values[b])

template bytes*(vals: var Values, id: Id): openArray[byte] =
  ## the full encoding bytes of any value
  let (start, len) = span(vals.values[id])
  vals.buf.toOpenArray(start, start + len - 1)

func scan*(vals: var Values): int =
  ## scans the buf and seeds the store
  let
    p = vals.buf
    avail = vals.buflen

  var
    parents: array[DepthLimit, Id]
    counts: array[DepthLimit, int] # children of each open frame
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
          psize = be32(p, off + 2)
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

func index*(vals: var Values) =
  ## Runs the indexing steps from the last watermark
  if vals.lastIndex >= vals.height:
    return
  if vals.lastIndex == 0:
    for b in Bucket:
      vals.buckets[b].setLen(0)

  vals.kidStart.setLen(vals.height + 1)
  var
    acc = if vals.lastIndex == 0: 0 else: vals.kidStart[vals.lastIndex]
    census: array[Kind, int]
  let accStart = acc
  for id in vals.lastIndex ..< vals.height:
    vals.kidStart[id] = acc
    acc += vals.values[id].len
    inc census[vals.values[id].kind]
  vals.kidStart[vals.height] = acc
  vals.kidBuf.setLen(acc)
  vals.parents.setLen(vals.height)

  var want: array[Bucket, int]
  want[ixRoot] = (vals.height - vals.lastIndex) - (acc - accStart)
  want[ixAtom] = census[bNil] + census[bNum] + census[bStr] +
    census[bSym] + census[bBytes]
  want[ixFrame] = census[bList] + census[bRec] + census[bDict] +
    census[bSet]
  want[ixNum] = census[bNum]
  want[ixText] = census[bStr] + census[bSym]
  want[ixRec] = census[bRec]
  want[ixSet] = census[bSet]
  want[ixDict] = census[bDict]

  var cur: array[Bucket, int]
  for b in Bucket:
    cur[b] = vals.buckets[b].len
    vals.buckets[b].setLen(cur[b] + want[b])

  template put(b: Bucket, id: Id) =
    vals.buckets[b][cur[b]] = id
    inc cur[b]

  var
    stack: array[DepthLimit, tuple[id: Id, endB, cur: int]]
    sp = 0
  for id in vals.lastIndex ..< vals.height:
    let
      v = vals.values[id]
    while sp > 0 and v.offset >= stack[sp - 1].endB:
      dec sp
    if sp > 0:
      vals.parents[id] = stack[sp - 1].id
      vals.kidBuf[stack[sp - 1].cur] = id
      inc stack[sp - 1].cur
    else:
      vals.parents[id] = -1
      put(ixRoot, id)
    let r = Route[v.kind]
    if r.hasLaw:
      put(r.law, id)
    put(r.group, id)
    if r.group == ixFrame:
      stack[sp] = (id: id, endB: v.offset + int(v.size),
        cur: vals.kidStart[id])
      inc sp
  vals.lastIndex = vals.height

template bucket*(vals: Values, b: Bucket): openArray[Id] =
  ## a bucket's ids as a view; index() first
  vals.buckets[b].toOpenArray(0, vals.buckets[b].len - 1)

template roots*(vals: Values): openArray[Id] =
  vals.bucket(ixRoot)

template kids*(vals: Values, id: Id): openArray[Id] =
  vals.kidBuf.toOpenArray(vals.kidStart[id], vals.kidStart[id + 1] - 1)

func parentOf*(vals: var Values, id: Id): Id =
  vals.parents[id]

# ================ validation ================

func validateText*(bytes: openArray[byte]) {.inline.} =
  if not validateUtf8(bytes.toOpenArrayChar(0, bytes.high)):
    refuse "validateText: utf8 not well formed"

func validateInt*(bytes: openArray[byte]) {.inline.} =
  if bytes.len == 0:
    refuse "validateInt: effective length cannot be 0"

  let
    isNegative = (bytes[0] == '-'.byte)
    start = if isNegative: 1 else: 0

  if bytes.len == start:
    refuse("validateInt: effective length cannot be 0")

  if bytes[start] == '0'.byte:
    if bytes.len - start > 1:
      refuse("validateInt: leading zeros are not allowed")
    if isNegative:
      refuse("validateInt: [-0] not a valid int")

  for i in start ..< bytes.len:
    if char(bytes[i]) notin {'0'..'9'}:
      refuse("validateInt: invalid char outside of [0-9]")

func validate*(vals: var Values) =
  if vals.lastIndex < vals.height:
    vals.index()
  for id in vals.buckets[ixNum]:
    validateInt(vals.payload(id))
  for id in vals.buckets[ixText]:
    validateText(vals.payload(id))
  for id in vals.buckets[ixRec]:
    reject vals.values[id].len == 0:
      "record with no head"
  for id in vals.buckets[ixDict]:
    let
      count = vals.values[id].len
      ks = vals.kidStart[id]
    reject count mod 2 != 0:
      "dict with a key missing its value"
    var i = 2
    while i < count:
      reject vals.cmpVals(vals.kidBuf[ks + i - 2], vals.kidBuf[ks + i]) >= 0:
        "dict keys out of order or duplicated"
      i += 2
  for id in vals.buckets[ixSet]:
    let
      count = vals.values[id].len
      ks = vals.kidStart[id]
    for i in 1 ..< count:
      reject vals.cmpVals(vals.kidBuf[ks + i - 1], vals.kidBuf[ks + i]) >= 0:
        "set members out of order or duplicated"