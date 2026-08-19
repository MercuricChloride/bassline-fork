include pkg/prelude
import std/hashes
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
    size: uint32 # size of the payload for atoms, zero for frames & nil
    stride: int # total value size

const
  EndByte = 0xA0'u8
  DepthLimit* = 64
  ScalarKinds* = {bInt, bStr, bSym, bBytes}
  FrameKinds* = {bList, bRec, bDict, bSet}

template tua*(v: pointer): ptr UncheckedArray[byte] =
  cast[ptr UncheckedArray[byte]](v)
template at(base: ptr UncheckedArray[byte], i: int): ptr UncheckedArray[byte] =
  ## the cursor's one move: a pointer i bytes in
  tua(addr base[i])
template toa*(v: ValueView): openArray[byte] =
  ## the value's bytes
  toOpenArray(v.p, 0, v.stride - 1)
template poa*(v: ValueView): openArray[byte] =
  ## the payload's bytes: the last `size` of the value's `stride`
  toOpenArray(v.p, v.stride - int(v.size), v.stride - 1)

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

# header byte lenses: [tag:4][mark:1][lbits:3]
func tag*(b: byte): byte {.inline.} =
  (b and 0xF0) shr 4
func mark*(b: byte): bool {.inline.} =
  (b and 0x08) != 0
func lbits*(b: byte): byte {.inline.} =
  b and 0x07
func kind*(b: byte): Kind {.inline.} =
  Kind(b.tag)
func tag*(v: ValueView): uint8 {.inline.} =
  v.p[0].tag
func mark*(v: ValueView): bool {.inline.} =
  v.p[0].mark
func kind*(v: ValueView): Kind {.inline.} =
  v.p[0].kind
func size*(v: ValueView): uint32 {.inline.} =
  v.size
func stride*(v: ValueView): int {.inline.} =
  v.stride

func be32(p: ptr UncheckedArray[byte], i: int): uint32 {.inline.} =
  ## the wire's big-endian u32 — shifts read it the same on any host
  (uint32(p[i]) shl 24) or (uint32(p[i + 1]) shl 16) or
    (uint32(p[i + 2]) shl 8) or uint32(p[i + 3])

func atomView(p: ptr UncheckedArray[byte]): ValueView {.inline.} =
  ## Stamped view of an already judged atom (nil included — its
  ## length bits are zero) in ONE branch chain: plain reads, no
  ## judging. The buffer is immutable and passed the door once.
  ## The judging twin of this chain lives in scan.
  let l = p[0].lbits
  if l < 7:
    ValueView(p: p, size: uint32(l), stride: 1 + int(l))
  elif p[1] != 255:
    ValueView(p: p, size: uint32(p[1]), stride: 2 + int(p[1]))
  else:
    let s = be32(p, 2)
    ValueView(p: p, size: s, stride: 6 + int(s))

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
  hash(v.toa)

func payload*(v: ValueView): (ptr UncheckedArray[byte], uint32) {.inline.} =
  ## Field math only: the payload occupies the last `size` bytes of
  ## the value's `stride` extent.
  reject v.kind notin ScalarKinds:
    "payload: only scalars carry a payload"
  (v.p.at(v.stride - int(v.size)), v.size)

# ================ DECODING ================

func scan(
    p: ptr UncheckedArray[byte], avail, maxDepth: int,
    content: static bool): int =
  ## Judges one complete value at p[0] and returns its byte extent.
  ## ONE while loop over the linear format: a frame header pushes
  ## onto a small explicit stack, END pops it and judges its laws —
  ## no recursion, no allocation, no call per node. Views are
  ## stamped at the doors. With content off only structure is
  ## judged; judgeContent is the other half.
  let cap = min(maxDepth, DepthLimit)
  var
    off = 0
    top = -1 # innermost open frame
    # noinit: 2.5KB zeroed per call would dwarf small values; every
    # entry is written at push before any read
    stack {.noinit.}: array[DepthLimit, tuple[
      kind: Kind, start: int, count: int,
      prevP: ptr UncheckedArray[byte], prevLen: int]]

  template parent: untyped = stack[top]

  template completeChild(childStart, childEnd: int) =
    ## the value [childStart, childEnd) just closed: judge it into
    ## its parent, or finish — a closed root is the whole judgment.
    ## prev tracks dict KEYS and set members only: the ordering law
    ## is key against key, never value against key.
    if top < 0:
      return childEnd
    if parent.kind == bSet or
        (parent.kind == bDict and parent.count mod 2 == 0):
      let
        cp = p.at(childStart)
        cl = childEnd - childStart
      if parent.prevP != nil and
          cmpBytes(parent.prevP, parent.prevLen, cp, cl) >= 0:
        if parent.kind == bSet:
          refuse "set members out of order or duplicated"
        refuse "dict keys out of order or duplicated"
      parent.prevP = cp
      parent.prevLen = cl
    inc parent.count

  while true:
    reject off >= avail:
      (if top < 0: "unexpected end of input"
       else: "unexpected end of input inside a frame")
    let b = p[off]
    case b.tag
    of 0x1:
      reject b.lbits != 0:
        "null with nonzero length bits"
      inc off
      completeChild(off - 1, off)
    of 0x2..0x5:
      # ONE pass over the length tiers: bounds, minimality, and size
      # judged together — the trusting twin of this chain is atomView
      let l = b.lbits
      var
        plen: uint32
        hdr: int
      if l < 7:
        plen = uint32(l)
        hdr = 1
      else:
        reject avail - off < 2:
          "unexpected end of input inside a length"
        let m = p[off + 1]
        if m != 255:
          reject m < 7:
            "non minimal med size"
          plen = uint32(m)
          hdr = 2
        else:
          reject avail - off < 6:
            "unexpected end of input inside a length"
          plen = be32(p, off + 2)
          reject plen < 255:
            "non minimal large size"
          hdr = 6
      let stride = hdr + int(plen)
      reject avail - off - hdr < int(plen):
        "unexpected end of input inside a payload"
      when content:
        case b.kind
        of bInt:
          validateInt(toOpenArray(p.at(off), hdr, stride - 1))
        of bStr, bSym:
          validateText(toOpenArray(p.at(off), hdr, stride - 1))
        else:
          discard
      off += stride
      completeChild(off - stride, off)
    of 0x6..0x9:
      reject b.lbits != 0:
        "frame header with nonzero length bits"
      reject top + 1 >= cap:
        "nesting past the depth limit"
      inc top
      parent = (kind: b.kind, start: off, count: 0,
        prevP: nil, prevLen: 0)
      inc off
    of 0xA:
      reject b != EndByte:
        "END carries no mark and no length"
      reject top < 0:
        "END where a value was expected"
      case parent.kind
      of bRec:
        reject parent.count == 0:
          "record with no head"
      of bDict:
        reject parent.count mod 2 != 0:
          "dict with a key missing its value"
      else:
        discard
      let frameStart = parent.start
      dec top
      inc off
      completeChild(frameStart, off)
    else:
      refuse "invalid tag"

func stamped(p: ptr UncheckedArray[byte], ext: int): ValueView {.inline.} =
  ## The door's stamp: bounds the scan already proved, written once
  ## into the view.
  if p[0].kind in FrameKinds:
    ValueView(p: p, size: 0, stride: ext)
  else:
    atomView(p)

func initValue*(
    buf: ptr UncheckedArray[byte], bufLen: int,
    maxDepth = DepthLimit,
    content: static bool = true): ValueView {.inline.} =
  ## The judging door: validates one complete CE value at buf[0] and
  ## returns a view of it, bounds stamped. The view carries its own
  ## extent, so this is also the stream door — advance by v.stride.
  ## content=false judges structure only — run judgeContent before
  ## letting views escape.
  stamped(buf, scan(buf, bufLen, maxDepth, content))

func initValue*(buf: openArray[byte], maxDepth = DepthLimit): ValueView {.inline.} =
  reject buf.len < 1:
    "unexpected end of input"
  initValue(tua(addr buf[0]), buf.len, maxDepth)

# ================ WALKING ================
## Per-level stepping (items/pairs/head) deliberately does NOT live
## here: deriving a child frame's extent from raw bytes per step is
## visibly quadratic under recursion. This layer's products are the
## doors, the linear walk, and O(1) reads on held views — structure
## beyond the stream is a consumer's to build, above raw views, from
## one walk.

iterator walk*(v: ValueView): ValueView =
  ## Every value in the tree, itself included, in encoded order —
  ## ONE linear pass with a cursor; each step is a header read.
  ## The root and every atom carry exact bounds. An interior frame
  ## is yielded on entry, before its region closes, so its bounds
  ## are zero.
  yield v
  if v.kind in FrameKinds:
    var
      off = 1
      open = 1
    while true:
      let b = v.p[off]
      case b.kind
      of bEnd:
        inc off
        dec open
        if open == 0: break
      of bNil..bBytes:
        let av = atomView(v.p.at(off))
        yield av
        inc off, av.stride
      of bList..bSet:
        yield ValueView(p: v.p.at(off))
        inc open
        inc off
      else:
        refuse "walk: invalid tag in judged bytes" # unreachable post-door

func nodeCount*(v: ValueView): int =
  ## Values in this tree
  for _ in v.walk:
    inc result

func judgeContent*(v: ValueView) =
  ## The content half of the judgment as its own linear pass over a
  ## structure-judged tree: integer spellings and utf8. Structure
  ## door (content=false) + this pass = the full rejection list.
  for c in v.walk:
    case c.kind
    of bInt:
      validateInt(c.poa)
    of bStr, bSym:
      validateText(c.poa)
    else:
      discard
