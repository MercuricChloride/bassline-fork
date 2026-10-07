import std/[strutils, hashes]
import ./buffer
import btree, codec
export btree, codec

refuseWith BasslineError

type
  BNum* = object
    case isWide: bool
    of false:
      small: int
    of true:
      big: string

converter toNum*(n: int): BNum =
  BNum(isWide: false, small: n)

func initNum*(s: string): BNum =
  ## s is a canonical spelling; past int64 it is held as it is spelled
  guard isValidInt(s.toBytes), "not a canonical number: " & s
  try:
    BNum(isWide: false, small: parseBiggestInt(s))
  except ValueError:
    BNum(isWide: true, big: s)

func toNum*(s: string): BNum =
  ## the number s spells, canonically; `toNum` of an int is the
  ## converter above
  initNum(s)

func isWide*(n: BNum): bool =
  n.isWide

func isInt*(n: BNum): bool =
  not n.isWide

func toInt*(n: BNum): int =
  guard n.isInt, "num is wide, not an int"
  n.small

func toString*(n: BNum): string =
  if n.isWide: n.big else: $n.small

func wide*(n: BNum): string =
  n.toString

func `$`*(n: BNum): string =
  n.toString

type
  BSet* = BTreeSet[Value]
  BDict* = BTree[Value, Value]

  Value* = object
    mark*: bool
    case kind*: Kind
    of bNil: discard
    of bNum:
      num*: BNum
    of bText, bSym:
      text*: string
    of bBytes:
      bytes*: seq[byte]
    of bList, bRec:
      items*: Buffer[Value]
    of bDict:
      dict*: BDict
    of bSet:
      els*: BSet

func newBSet*(): BSet =
  newBTreeSet[Value]()

func newBDict*(): BDict =
  newBTree[Value, Value]()

func null*(mark = false): Value =
  Value(kind: bNil, mark: mark)

func num*(n: int, mark = false): Value =
  Value(kind: bNum, mark: mark, num: n)

func num*(n: string, mark = false): Value =
  Value(kind: bNum, mark: mark, num: initNum(n))

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
  Value(kind: bSet, els: newBTreeSet[Value](), mark: mark)

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

func spellingLen*(x: BNum): int =
  if x.isWide:
    x.wide.len
  else:
    x.toInt.spellingLen

func cmpNums*(x, y: int): int =
  ## ascii shortlex over the decimal strings
  ## without making them strings
  diff spellingLen(x), spellingLen(y)
  let nx = x < 0
  let ny = y < 0
  if nx != ny:
    return if nx: -1 else: 1
  diff magnitude(x), magnitude(y)

func cmpNums*(x, y: BNum): int =
  if x.isWide or y.isWide:
    cmpShortlex(x.wide.toBytes, y.wide.toBytes)
  else:
    cmpNums(x.toInt, y.toInt)

func cmp*(a, b: Value): int =
  diff a.kind, b.kind
  diff a.mark, b.mark
  case a.kind
  of bNil: discard
  of bNum:
    result = cmpNums(a.num, b.num)
  of bText, bSym:
    result = cmpShortlex(a.text.toBytes, b.text.toBytes)
  of bBytes:
    result = cmpShortlex(a.bytes, b.bytes)
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
      diff ea, eb
    diff b.els.len, a.els.len

func `==`*(a, b: Value): bool =
  cmp(a, b) == 0

func `<`*(a, b: Value): bool =
  cmp(a, b) < 0

func `<=`*(a, b: Value): bool =
  cmp(a, b) <= 0

func `>`*(a, b: Value): bool =
  cmp(a, b) > 0

func `>=`*(a, b: Value): bool =
  cmp(a, b) >= 0

# ================ Access ================

func len*(a: Value): int =
  case a.kind
  of bList, bRec: a.items.len
  of bDict: a.dict.len
  of bSet: a.els.len
  else: 0

func isKind*(a: Value, k: set[Kind]): bool =
  a.kind in k

func isKind*(a: Value, k: Kind): bool =
  a.kind == k

# the message is built only on failure: a default parameter would build
# it on every call

func expectKind*(a: Value, k: Kind) =
  guard a.isKind(k), "expected kind: " & $k

func expectKind*(a: Value, k: Kind, msg: string) =
  guard a.isKind(k), msg

func expectKind*(a: Value, k: set[Kind]) =
  guard a.isKind(k), "expected value of kind: " & $k

func expectKind*(a: Value, k: set[Kind], msg: string) =
  guard a.isKind(k), msg

func `[]`*(a: Value, i: Natural): lent Value =
  a.expectKind {bList, bRec}
  a.items[i]

func `[]`*(a: Value, k: Value): lent Value =
  a.expectKind bDict
  a.dict[k]

# ================ Frame constructors ================

func initList*(items: sink seq[Value], mark = false): Value =
  Value(kind: bList, items: newBuffer(items), mark: mark)

proc initRec*(items: sink seq[Value], mark = false): Value =
  doAssert items.len > 0, "a record needs a head"
  Value(kind: bRec, items: newBuffer(items), mark: mark)

proc initSet*(items: sink seq[Value], mark = false): Value =
  result = initSet(mark)
  for x in items.mitems:
    result.els.incl move(x)

proc initDict*(entries: sink seq[(Value, Value)], mark = false): Value =
  result = initDict(mark)
  for e in entries.mitems:
    result.dict[move e[0]] = move e[1]

proc initRec*(items: Buffer[Value], mark = false): Value =
  guard items.len > 0, "record must have a head"
  Value(kind: bRec, items: items, mark: mark)

func initList*(items: Buffer[Value], mark = false): Value =
  Value(kind: bList, items: items, mark: mark)

func initDict*(dict: BDict, mark = false): Value =
  Value(kind: bDict, dict: dict, mark: mark)

func initSet*(els: BSet, mark = false): Value =
  Value(kind: bSet, els: els, mark: mark)

func head*(v: Value): lent Value =
  guard v.kind in {bList, bRec}, "head must be used with a list / record"
  return v.items[0]

template toBSet*(iter): BSet =
  var r = newBSet()
  for each in iter:
    r.incl each
  r

# ================ Misc converstion fns ================

func toValue*(v: Value): Value = 
  v

func fromValue*(T: typedesc[Value], v: Value): Value =
  v

func toValue*(i: SomeInteger): Value = 
  num(i)

func toValue*(self: BNum): Value =
  Value(kind: bNum, num: self)

func toValue*(s: string): Value = 
  text(s)

func toValue*(self: BDict): Value =
  initDict(self)

func toValue*(self: BSet): Value =
  initSet(self)

func toValue*(self: Buffer[Value]): Value =
  initList(self)

func toValue*(b: openArray[byte]): Value = 
  bytes(b)

func toValue*[T](xs: openArray[T]): Value =
  mixin toValue
  result = initList()
  for x in xs:
    result.items.add toValue(x)

proc `%>`*[T](self: T): Value =
  mixin toValue
  toValue(self)

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
      for val in v.els:
        e.write val

proc ce*(v: Value): seq[byte] =
  ## a value's CE bytes
  let e = newEncoder()
  e.write v
  e.buf.data

proc hash*(v: Value): Hash =
  let b = v.ce
  hashData(addr b[0], b.len)

proc hash*(v: ValueView): Hash =
  let b = @(v.ce)
  hashData(addr b[0], b.len)

proc toValue*(view: ValueView): Value =
  case view.kind
  of bNil:
    return null(view.mark)
  of bNum:
    let s = view.payloadBytes.toString()
    return num(s, view.mark)
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

iterator decode*(_: typedesc[Value], ce: openArray[byte]): Value =
  for view in ValueView.decode(ce):
    yield view.toValue

proc decode*(_: typedesc[Value], ce: openArray[byte]): Value =
  ValueView.decode(ce).toValue

proc toView*(self: Value): ValueView =
  var
    buf = newBuffer[byte]()
    e = newEncoder(buf)
    d = newDecoder(buf)
  e.write self
  for v in d.unchecked:
    return v