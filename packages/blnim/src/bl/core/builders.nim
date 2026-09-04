import std/strutils
import ./buffer
import btree, codec
export btree, codec

type
  Value* = object
    mark*: bool
    case kind*: Kind
    of bNil: discard
    of bNum:
      num*: int
    of bText, bSym:
      text*: string
    of bBytes:
      bytes*: seq[byte]
    of bList, bRec:
      items*: Buffer[Value]
    of bDict:
      dict*: BTree[Value, Value]
    of bSet:
      els*: BTree[Value, bool]

func null*(mark = false): Value =
  Value(kind: bNil, mark: mark)

func num*(n: int, mark = false):  Value =
  Value(kind: bNum, mark: mark, num: n)

func text*(t: string, mark = false): Value =
  Value(kind: bText, text: t, mark: mark)

func sym*(t: string, mark = false): Value =
  Value(kind: bSym, text: t, mark: mark)

func bytes*(b: sink seq[byte], mark = false): Value =
  Value(kind: bBytes, bytes: b, mark: mark)

func bytes*(b: openArray[byte], mark = false): Value =
  bytes(@b, mark)

func initList*(mark = false): Value =
  Value(kind: bList, items: newBuffer[Value](), mark: mark)

proc initRec*(head: Value, mark = false): Value =
  Value(kind: bRec, items: newBuffer(@[head]), mark: mark)

func initDict*(mark = false): Value =
  Value(kind: bDict, dict: newBTree[Value, Value](), mark: mark)

func initSet*(mark = false): Value =
  Value(kind: bSet, els: newBTree[Value, bool](), mark: mark)

# ================ Comparators ================

template diff(a, b) =
  result = cmp(a, b)
  if result != 0: return

func magnitude(x: int): uint64 =
  ## |x| without the abs(int.low) overflow
  if x < 0: uint64(-(x + 1)) + 1
  else: uint64(x)

func spellingLen*(x: int): int =
  ## the length of the canonical decimal spelling of x
  result = 1
  if x < 0:
    inc result
  var m = magnitude(x)
  while m >= 10:
    m = m div 10
    inc result

func cmpNums*(x, y: int): int =
  ## ascii shortlex over the decimal strings
  ## without making them strings
  diff spellingLen(x), spellingLen(y)
  let nx = x < 0
  let ny = y < 0
  if nx != ny:
    return if nx: -1 else: 1
  diff magnitude(x), magnitude(y)

func cmpStrings*(x, y: string): int =
  cmpBytes(x.toBytes, y.toBytes)

func cmp*(a, b: Value): int =
  diff a.kind, b.kind
  diff a.mark, b.mark
  case a.kind
  of bNil: discard
  of bNum:
    result = cmpNums(a.num, b.num)
  of bText, bSym:
    diff a.text.len, b.text.len
    result = cmpBytes(a.text.toBytes, b.text.toBytes)
  of bBytes:
    diff a.bytes.len, b.bytes.len
    result = cmpBytes(a.bytes, b.bytes)
  of bList, bRec:
    for i in 0 ..< min(a.items.len, b.items.len):
      diff a.items[i], b.items[i]
    # this looks backwards, but frames are terminated with 0xA0
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

func `<`*(a, b: Value): bool =
  cmp(a, b) < 0

# ================ Frame constructors ================

func initList*(items: sink seq[Value], mark = false): Value =
  Value(kind: bList, items: newBuffer(items), mark: mark)

proc initRec*(items: sink seq[Value], mark = false): Value =
  doAssert items.len > 0, "a record needs a head"
  Value(kind: bRec, items: newBuffer(items), mark: mark)

proc initSet*(items: sink seq[Value], mark = false): Value =
  result = initSet(mark)
  for x in items:
    result.els[x] = true

proc initDict*(entries: sink seq[(Value, Value)], mark = false): Value =
  result = initDict(mark)
  for (k, v) in entries:
    result.dict[k] = v

# ================ Misc converstion fns ================

func toValue*(v: Value): Value = 
  v

func toValue*(i: int): Value = 
  num(i)

func toValue*(i: int64): Value = 
  num(int(i))

func toValue*(s: string): Value = 
  text(s)

func toValue*(b: seq[byte]): Value = 
  bytes(b)

proc toValue*[T](xs: openArray[T]): Value =
  mixin toValue
  result = initList()
  for x in xs:
    result.items.add toValue(x)

# ================ Encoding ================

proc write*(e: Encoder, v: Value) =
  template scalar(b: openArray[byte]) =
    e.putScalar(v.kind, v.mark, b)

  template frame(body) =
    e.frame(v.kind, v.mark):
      body
  
  case v.kind
  of bNil: 
    scalar []
  of bNum:
    scalar toBytes $v.num
  of bText, bSym:
    scalar toBytes v.text
  of bBytes:
    scalar v.bytes
  of bList, bRec:
    frame:
      for child in v.items:
        e.write child
  of bDict:
    frame:
      for key, val in v.dict:
        e.write key
        e.write val
  of bSet:
    frame:
      for val, _ in v.els:
        e.write val

proc toValue*(view: ValueView): Value =
  case view.kind
  of bNil:
    return null(view.mark)
  of bNum:
    let s = view.payloadBytes.toString()
    try:
      return num(parseBiggestInt(s), view.mark)
    except ValueError:
      raise newException(ValueError, "numeral outside int64: " & s)
  of bText:
    return text(view.payloadBytes.toString(), view.mark)
  of bSym:
    return sym(view.payloadBytes.toString(), view.mark)
  of bBytes:
    return bytes(@(view.payloadBytes), view.mark)
  of bList:
    result = initList(view.mark)
    for child in view.children:
      result.items.add child.toValue
  of bRec:
    result = initRec(toValue(view.children[0]), view.mark)
    for i in 1..<view.children.len:
      result.items.add toValue(view.children[i])
  of bSet:
    result = initSet(view.mark)
    for child in view.children:
      result.els.incl child.toValue
  of bDict:
    result = initDict(view.mark)
    for (key, val) in view.entries:
      result.dict[key.toValue] = val.toValue