import std/strutils
import btree, codec
export btree, codec

type
  Kind* = enum
    bNil,
    bNum, bText, bSym, bBytes,
    bList, bRec, bDict, bSet

  Value* = object
    marked*: bool
    case kind*: Kind
    of bNil: discard
    of bNum:
      num*: int
    of bText, bSym:
      text*: string
    of bBytes:
      bytes*: seq[byte]
    of bList, bRec:
      items*: seq[Value]
    of bDict:
      dict*: BTree[Value, Value]
    of bSet:
      els*: BTree[Value, bool]

func null*(marked = false): Value =
  Value(kind: bNil, marked: marked)

func num*(n: int, marked = false):  Value =
  Value(kind: bNum, marked: marked, num: n)

func text*(t: string, marked = false): Value =
  Value(kind: bText, text: t, marked: marked)

func sym*(t: string, marked = false): Value =
  Value(kind: bSym, text: t, marked: marked)

func bytes*(b: sink seq[byte], marked = false): Value =
  Value(kind: bBytes, bytes: b, marked: marked)

func initList*(marked = false): Value =
  Value(kind: bList, items: @[], marked: marked)

func initRec*(head: Value, marked = false): Value =
  Value(kind: bRec, items: @[head], marked: marked)

func initDict*(marked = false): Value =
  Value(kind: bDict, dict: initBTree[Value, Value](), marked: marked)

func initSet*(marked = false): Value =
  Value(kind: bSet, els: initBTree[Value, bool](), marked: marked)

template diff(a, b) =
  result = cmp(a, b)
  if result != 0: return

func magnitude(x: int): uint64 =
  if x < 0: 0'u64 - cast[uint64](x) else: uint64(x)

func spellingLen*(x: int): int =
  ## the length of the canonical decimal spelling of x
  var m = magnitude(x)
  result = if x < 0: 2 else: 1
  while m >= 10:
    m = m div 10
    inc result

func cmp*(a, b: Value): int =
  diff a.kind, b.kind
  diff a.marked, b.marked
  case a.kind
  of bNil: discard
  of bNum:
    # shortlex over the decimal spellings, without spelling them:
    # length first (the sign counts), then '-' before any digit, then
    # the digits -- which for equal length and sign is magnitude order
    let x = a.num
    let y = b.num
    diff spellingLen(x), spellingLen(y)
    let nx = x < 0
    let ny = y < 0
    if nx != ny:
      return if nx: -1 else: 1
    diff magnitude(x), magnitude(y)
  of bText, bSym:
    diff a.text.len, b.text.len
    result = cmpBytes(a.text.toOpenArrayByte(0, a.text.high),
                      b.text.toOpenArrayByte(0, b.text.high))
  of bBytes:
    diff a.bytes.len, b.bytes.len
    result = cmpBytes(a.bytes, b.bytes)
  of bList, bRec:
    for i in 0 ..< min(a.items.len, b.items.len):
      diff a.items[i], b.items[i]
    # looks backwards, but matches that frames are terminated with 0xA0
    # which causes shorter frames to be > longer frames
    diff b.items.len, a.items.len
  of bDict:
    for ea, eb in lockstep(a.dict, b.dict):
      diff ea.key, eb.key
      diff ea.val, eb.val
    # a shorter frame sorts after the longer: END (0xA0) > any header
    diff b.dict.len, a.dict.len
  of bSet:
    for ea, eb in lockstep(a.els, b.els):
      diff ea.key, eb.key
    diff b.els.len, a.els.len

func `==`*(a, b: Value): bool =
  cmp(a, b) == 0
func `!=`*(a, b: Value): bool =
  cmp(a, b) != 0
func `<`*(a, b: Value): bool =
  cmp(a, b) < 0
func `>`*(a, b: Value): bool =
  cmp(a, b) > 0
func `<=`*(a, b: Value): bool =
  cmp(a, b) <= 0
func `>=`*(a, b: Value): bool =
  cmp(a, b) >= 0

# ================ Frame constructors ================

func toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

func initList*(items: sink seq[Value], marked = false): Value =
  Value(kind: bList, items: items, marked: marked)

func initRec*(items: sink seq[Value], marked = false): Value =
  doAssert items.len > 0, "a record needs a head"
  Value(kind: bRec, items: items, marked: marked)

proc initSet*(items: sink seq[Value], marked = false): Value =
  result = initSet(marked)
  for x in items:
    result.els[x] = true

proc initDict*(entries: sink seq[(Value, Value)], marked = false): Value =
  result = initDict(marked)
  for (k, v) in entries:
    result.dict[k] = v

func toValue*(v: Value): Value = v
func toValue*(i: int): Value = num(i)
func toValue*(i: int64): Value = num(int(i))
func toValue*(s: string): Value = text(s)
func toValue*(b: seq[byte]): Value = bytes(b)

func toValue*[T](xs: seq[T]): Value =
  mixin toValue
  result = initList()
  for x in xs:
    result.items.add toValue(x)

# ================ Spelling ================
# Value → canonical bytes. The trees already hold dicts and sets in
# CE order, so spelling is a straight walk with no sorting; finalize
# is the one validation point (bad text handed to a constructor
# surfaces here).

func tag*(k: Kind): ValueTag =
  ValueTag(ord(k) + 1)

func spell*(e: var Encoder, v: Value) =
  case v.kind
  of bNil: e.putNil(v.marked)
  of bNum: e.putNum(v.num, v.marked)
  of bText: e.putText(v.text, v.marked)
  of bSym: e.putSym(v.text, v.marked)
  of bBytes: e.putBytes(v.bytes, v.marked)
  of bList, bRec:
    e.putOpen(tag(v.kind), v.marked)
    for c in v.items:
      e.spell(c)
    e.putClose()
  of bSet:
    e.putOpen(vSet, v.marked)
    for k, _ in v.els:
      e.spell(k)
    e.putClose()
  of bDict:
    e.putOpen(vDict, v.marked)
    for k, val in v.dict:
      e.spell(k)
      e.spell(val)
    e.putClose()

func spell*(v: Value): seq[byte] =
  ## The vouched spelling of `v`: one Encoder walk, then finalize.
  var e = initEncoder()
  e.spell(v)
  e.finalize()

# ================ Drafting a judged value ================

func directChildren(spans: openArray[Span], i: int): int =
  ## how many direct children the frame at `i` has: index arithmetic
  ## only, so a frame's seq is allocated once at the right size
  var j = i + 1
  while j <= i + spans[i].count:
    inc result
    j += spans[j].count + 1

proc draft*(data: openArray[byte], spans: openArray[Span], i = 0): Value =
  ## Bring the judged value at `i` into the Nim-owned domain: a copying
  ## walk over the span list — every payload is copied, nothing points
  ## back into `data`. No checks: judge already proved shape, content,
  ## and order, and spans carry the payload offsets.
  let s = spans[i]
  template payloadStr(): string =
    var r = newString(s.hi - s.payLo)
    if r.len > 0:
      copyMem(addr r[0], addr data[s.payLo], r.len)
    r
  case s.kind
  of vNil:
    result = null(s.marked)
  of vNum:
    let spelling = payloadStr()
    try:
      result = num(int(parseBiggestInt(spelling)), s.marked)
    except ValueError:
      raise newException(ValueError, "numeral outside int64: " & spelling)
  of vText:
    result = text(payloadStr(), s.marked)
  of vSym:
    result = sym(payloadStr(), s.marked)
  of vBytes:
    var b = newSeq[byte](s.hi - s.payLo)
    if b.len > 0:
      copyMem(addr b[0], addr data[s.payLo], b.len)
    result = bytes(b, s.marked)
  of vList, vRec:
    var kids = newSeqOfCap[Value](directChildren(spans, i))
    var j = i + 1
    while j <= i + s.count:
      kids.add draft(data, spans, j)
      j += spans[j].count + 1
    result = if s.kind == vList: initList(kids, s.marked)
             else: initRec(kids, s.marked)
  of vSet:
    result = initSet(s.marked)
    var j = i + 1
    while j <= i + s.count:
      result.els[draft(data, spans, j)] = true
      j += spans[j].count + 1
  of vDict:
    result = initDict(s.marked)
    var j = i + 1
    while j <= i + s.count:
      let k = draft(data, spans, j)
      j += spans[j].count + 1
      result.dict[k] = draft(data, spans, j)
      j += spans[j].count + 1
