include pkg/prelude
import std/[endians, hashes]
import ./validation

type
  RefuseError* = object of CatchableError
  Kind* = enum
    bInvalid = 0x0
    bNil = 0x1
    bInt = 0x2
    bStr = 0x3
    bSym = 0x4
    bBytes = 0x5
    bList = 0x6
    bRec = 0x7
    bDict = 0x8
    bSet = 0x9
    bEnd = 0xA
  ValueView* = object
    p: ptr UncheckedArray[byte]

const
  EndByte = 0xA0'u8
  DepthLimit* = 64
  ScalarKinds* = {bInt, bStr, bSym, bBytes}
  FrameKinds* = {bList, bRec, bDict, bSet}

template tua*(v: pointer): ptr UncheckedArray[byte] =
  cast[ptr UncheckedArray[byte]](v)
template toa*(v: ValueView): openArray[byte] =
  toOpenArray(v.p, 0, v.stride - 1)

func refuse*(msg: string) {.noreturn.} =
  raise newException(RefuseError, msg)

template reject*(cond, msg: untyped): untyped =
  if cond:
    refuse msg

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

func tag(v: ValueView): uint8 {.inline.} =
  (v.p[0] and 0xF0) shr 4
func mark*(v: ValueView): bool {.inline.} =
  (v.p[0] and 0x08) != 0
func kind*(v: ValueView): Kind {.inline.} =
  Kind(v.tag())

func size*(v: ValueView): int {.inline.} =
  result = int(v.p[0] and 0x07)
  # small len
  if result != 7:
    return result
  # med len
  result = int(v.p[1])
  if result < 7:
    refuse "non minimal med size"
  if result != 255:
    return result
  # large len
  var raw, clean: uint32
  copyMem(addr(raw), addr(v.p[2]), sizeof(uint32))
  bigEndian32(addr(clean), addr(raw))
  result = int(clean)
  if result < 255:
    refuse "non minimal large size"
  return result

func stride*(v: ValueView): int =
  ## Returns the total footprint of this value in bytes, END included
  ## for frames.
  case v.kind
  of bInt..bBytes:
    let s = v.size
    case s
    of 0..6:
      result = 1 + s
    of 7..254:
      result = 2 + s
    else:
      result = 6 + s
  of bList..bSet:
    result = 1
    while v.p[result] != EndByte:
      result += ValueView(p: tua(addr v.p[result])).stride
    inc result
  else:
    result = 1

func cmpBytes(
    a: ptr UncheckedArray[byte], alen: int,
    b: ptr UncheckedArray[byte], blen: int): int =
  result = cmpMem(a, b, min(alen, blen))
  if result != 0: return
  ## Because frames are delimited with 0xA0 and that byte is > all
  ## other CE header bytes, a frame that is a prefix of a longer frame
  ## sorts AFTER it, its END shows up where the longer frame still has
  ## constituents.
  result = cmp(blen, alen)

func cmp*(a, b: ValueView): int =
  cmpBytes(a.p, a.stride, b.p, b.stride)

func `==`*(a, b: ValueView): bool =
  cmp(a, b) == 0

func hash*(v: ValueView): Hash =
  ## The hash of a value is the hash of its bytes.
  hash(toOpenArray(v.p, 0, v.stride - 1))

func payload*(v: ValueView): (ptr UncheckedArray[byte], int) {.inline.} =
  reject v.kind notin ScalarKinds:
    "payload: only scalars carry a payload"
  let s = v.size
  case s
  of 0..6:
    (tua(addr(v.p[1])), s)
  of 7..254:
    (tua(addr(v.p[2])), s)
  else:
    (tua(addr(v.p[6])), s)

# ================ DECODING ================

func scan(p: ptr UncheckedArray[byte], avail, depth: int): (ValueView, int) =
  ## scan for one complete value at p[0] and returns it + it's byte extent.
  ## Reads are bounded by avail and nesting is bounded by depth.
  reject avail < 1:
    "unexpected end of input"
  let
    view = ValueView(p: p)
    t = view.tag

  case t
  of 0x1:
    reject (p[0] and 0x07) != 0:
      "null with nonzero length bits"
    (view, 1)
  of 0x2..0x5:
    var start = 1
    if (p[0] and 0x07) == 7:
      reject avail < 2:
        "unexpected end of input inside a length"
      if p[1] == 255:
        reject avail < 6:
          "unexpected end of input inside a length"
        start = 6
      else:
        start = 2
    # size judges length minimality on the way through payload
    let (pl, plen) = view.payload
    reject avail - start < plen:
      "unexpected end of input inside a payload"
    case view.kind
    of bInt:
      validateInt(pl.toOpenArray(0, plen - 1))
    of bStr, bSym:
      validateText(pl.toOpenArray(0, plen - 1))
    else:
      discard
    (view, start + plen)
  of 0x6..0x9:
    reject (p[0] and 0x07) != 0:
      "frame header with nonzero length bits"
    reject depth < 1:
      "nesting past the depth limit"
    let k = view.kind
    var
      off = 1
      count, prevLen = 0
      prev: ValueView
    while true:
      reject off >= avail:
        "unexpected end of input inside a frame"
      if p[off] == EndByte:
        inc off
        break
      let
        (child, childLen) = scan(tua(addr p[off]), avail - off, depth - 1)
      # dict keys sit at even positions, set members everywhere;
      # both must be unique and strictly ascending by CE bytes
      if k == bSet or (k == bDict and count mod 2 == 0):
        if (prev.p != nil) and cmpBytes(prev.p, prevLen, child.p, childLen) >= 0:
          if k == bSet:
            refuse "set members out of order or duplicated"
          refuse "dict keys out of order or duplicated"
        prev = child
        prevLen = childLen
      inc count
      inc off, childLen
    case k
    of bRec:
      reject count == 0:
        "record with no head"
    of bDict:
      reject count mod 2 != 0:
        "dict with a key missing its value"
    else: discard
    (view, off)
  of 0xA:
    reject p[0] != EndByte:
      "END carries no mark and no length"
    refuse "END where a value was expected"
  else:
    refuse "invalid tag"

func initValue*(
    buf: ptr UncheckedArray[byte], bufLen: int,
    maxDepth = DepthLimit): ValueView {.inline.} =
  ## The judging door: validates one complete CE value at buf[0] and
  ## returns a view of it. Trailing bytes are left for the caller —
  ## a stream carries many values, each initValue judges one.
  result = scan(buf, bufLen, maxDepth)[0]

func initValue*(buf: openArray[byte], maxDepth = DepthLimit): ValueView =
  reject buf.len < 1:
    "unexpected end of input"
  initValue(tua(addr buf[0]), buf.len, maxDepth)

func nextValue*(
    buf: ptr UncheckedArray[byte], bufLen: int,
    maxDepth = DepthLimit): tuple[value: ValueView, len: int] {.inline.} =
  ## The stream door: judges the first value in the buffer and also
  ## returns its byte extent, so a caller stepping through many
  ## values doesn't re-walk each one for its stride.
  let (v, n) = scan(buf, bufLen, maxDepth)
  (value: v, len: n)

# ================ WALKING ================

iterator items*(v: ValueView): ValueView =
  ## Constituents of a frame, in encoded order.
  reject v.kind notin FrameKinds:
    "items: not a frame"
  var off = 1
  while v.p[off] != EndByte:
    let c = ValueView(p: tua(addr v.p[off]))
    yield c
    off += c.stride

iterator pairs*(v: ValueView): tuple[key, val: ValueView] =
  ## Associations of a dict, in canonical (key-sorted) order.
  reject v.kind != bDict:
    "pairs: not a dict"
  var off = 1
  while v.p[off] != EndByte:
    let key = ValueView(p: tua(addr v.p[off]))
    off += key.stride
    let val = ValueView(p: tua(addr v.p[off]))
    off += val.stride
    yield (key, val)

iterator walk*(v: ValueView): ValueView =
  ## Every value in the tree, itself included, in encoded order —
  ## ONE linear pass with a cursor. The format is linear and the
  ## buffer is judged and immutable, so each step is a header read:
  ## frames open, END closes, scalars jump their payload.
  var
    off = 0
    open = 0
  while true:
    let h = v.p[off]
    if h == EndByte:
      inc off
      dec open
      if open == 0:
        break
      continue
    yield ValueView(p: tua(addr v.p[off]))
    case (h and 0xF0) shr 4
    of 0x6 .. 0x9:
      inc open
      inc off
    of 0x2 .. 0x5:
      let lbits = int(h and 0x07)
      if lbits < 7:
        off += 1 + lbits
      elif v.p[off + 1] != 255:
        off += 2 + int(v.p[off + 1])
      else:
        off += 6 + int(
          (uint32(v.p[off + 2]) shl 24) or (uint32(v.p[off + 3]) shl 16) or
          (uint32(v.p[off + 4]) shl 8) or uint32(v.p[off + 5]))
    else:
      inc off
    if open == 0:
      break

func count*(v: ValueView): int =
  ## Number of constituents of a frame (a dict counts each key and value).
  for _ in v.items:
    inc result

func head*(v: ValueView): ValueView =
  ## The head of a record — the topic its fields discuss.
  reject v.kind != bRec:
    "head: not a record"
  for c in v.items:
    return c

func nodesAt(p: ptr UncheckedArray[byte]): (int, int) =
  let v = ValueView(p: p)
  if v.kind notin FrameKinds:
    return (1, v.stride)
  var
    off = 1
    nodes = 1
  while p[off] != EndByte:
    let (n, e) = nodesAt(tua(addr p[off]))
    nodes += n
    off += e
  (nodes, off + 1)

func nodeCount*(v: ValueView): int =
  ## Values in this tree, itself included — ONE pass over the bytes,
  ## deriving each extent from the recursion. items + stride
  ## recursion re-walks every subtree once per enclosing level, which
  ## goes quadratic on deep chains.
  nodesAt(v.p)[0]