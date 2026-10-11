import std/[hashes, options]
import ./[shared, codec]
export btree, codec, options

refuseWith BasslineError

type
  BSet* = BTreeSet[Value]
  BDict* = BTree[Value, Value]
  BSeq* = Buffer[Value]
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
    of bList, bRec, bDict, bSet:
      frame*: Frame

func newBSet*(): BSet =
  newBTreeSet[Value]()

func newBDict*(): BDict =
  newBTree[Value, Value]()

func copy*(f: Frame): Frame =
  if f of BSeq:
    return BSeq(f).copy
  elif f of BDict:
    return BDict(f).copy
  elif f of BSet:
    return BSet(f).copy
  else:
    refuse "unknown frame"

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
  Value(kind: bList, frame: newBuffer[Value](), mark: mark)

proc initRec*(head: Value, mark = false): Value =
  Value(kind: bRec, frame: newBuffer(@[head]), mark: mark)

func initDict*(mark = false): Value =
  Value(kind: bDict, frame: newBTree[Value, Value](), mark: mark)

func initSet*(mark = false): Value =
  Value(kind: bSet, frame: newBTreeSet[Value](), mark: mark)

func items*(self: Value): BSeq =
  guard self.frame of BSeq, "not a BSeq"
  BSeq(self.frame)

func dict*(self: Value): BDict =
  guard self.frame of BDict, "not a BDict"
  BDict(self.frame)

func els*(self: Value): BSet =
  guard self.frame of BSet, "not a BSet"
  BSet(self.frame)

# ================ Comparators ================

template diff(a, b) =
  result = cmp(a, b)
  if result != 0: return

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

const
  anyMark* = none(bool)
  unmarked* = some(false)
  marked* = some(true)

func isKind*(a: Value, k: set[Kind], mark = anyMark): bool =
  a.kind in k and (
    if mark.isSome: a.mark == mark.get else: true
  )

func isKind*(a: Value, k: Kind, mark = anyMark): bool =
  a.isKind({k}, mark)

func expectKind*(a: Value, k: set[Kind], mark = anyMark) =
  guard a.isKind(k, mark),
    "expected value of kind: " & $k & $mark

func expectKind*(a: Value, k: Kind, mark = anyMark) =
  expectKind(a, {k}, mark)

func `[]`*(a: Value, i: Natural): lent Value =
  a.expectKind {bList, bRec}
  a.items[i]

func `[]`*(a: Value, i: BackwardsIndex): lent Value =
  a.expectKind {bList, bRec}
  a.items[i]

func `[]`*(a: Value, i: BNum): lent Value =
  a[i.toInt]

func `[]`*(a: Value, k: Value): lent Value =
  a.expectKind bDict
  a.dict[k]

func `[]=`*(a: var Value, i: Natural, val: Value) =
  a.items[i] = val

func `[]=`*(a: var Value, i: BNum, val: Value) =
  a[i.toInt] = val

func add*(a: var Value, el: sink Value) =
  a.expectKind({bList, bRec})
  a.items.add el

func pop*(a: var Value): Value =
  a.expectKind({bList, bRec})
  if a.isKind(bRec):
    guard a.len > 1, "cant pop the head of a record"
  a.items.data.pop()

func `[]=`*(a: var Value, k, v: Value) =
  a.expectKind(bDict)
  a.dict[k] = v

func incl*(a: var Value, v: Value) =
  a.expectKind(bSet)
  a.els.incl v

iterator children*(self: Value): Value =
  case self.kind
  of bList, bRec:
    for v in self.items: 
      yield v
  of bDict:
    for k, v in self.dict:
      yield k; yield v
  of bSet:
    for v in self.els:
      yield v
  else: discard

iterator walk*(self: Value): Value {.closure.} =
  yield self
  for v in self.children:
    for each in v.walk:
      yield each

# ================ Frame constructors ================

func initList*(items: sink seq[Value], mark = false): Value =
  Value(kind: bList, frame: newBuffer(items), mark: mark)

func initList*(items: openArray[Value] = [], mark = false): Value =
  initList(@items, mark)

func initRec*(items: sink seq[Value], mark = false): Value =
  doAssert items.len > 0, "a record needs a head"
  Value(kind: bRec, frame: newBuffer(items), mark: mark)

func initRec*(head: Value, items: openArray[Value], mark = false): Value =
  var l = newSeqOfCap[Value](items.len + 1)
  l &= head
  l &= items
  initRec(l, mark)

func initRec*(items: openArray[Value], mark = false): Value =
  initRec(@items, mark)

func initSet*(items: sink seq[Value], mark = false): Value =
  result = initSet(mark)
  for x in items.mitems:
    result.els.incl move(x)

func initSet*(items: openArray[Value], mark = false): Value =
  initSet(@items, mark)

proc initDict*(entries: sink seq[(Value, Value)], mark = false): Value =
  result = initDict(mark)
  for e in entries.mitems:
    result.dict[move e[0]] = move e[1]

proc initDict*(entries: openArray[(Value, Value)], mark = false): Value =
  initDict(@entries, mark)

proc initRec*(items: Buffer[Value], mark = false): Value =
  guard items.len > 0, "record must have a head"
  Value(kind: bRec, frame: items, mark: mark)

func initList*(items: Buffer[Value], mark = false): Value =
  Value(kind: bList, frame: items, mark: mark)

func initDict*(dict: BDict, mark = false): Value =
  Value(kind: bDict, frame: dict, mark: mark)

func initSet*(els: BSet, mark = false): Value =
  Value(kind: bSet, frame: els, mark: mark)

func head*(v: Value): lent Value =
  guard v.isKind({bList, bRec}): "head must be used with a list / record"
  return v[0]

template toBSet*(iter): BSet =
  var r = newBSet()
  for each in iter:
    r.incl each
  r

func copy*(self: Value): Value =
  case self.kind
  of bNil..bBytes: self
  of bList:
    initList(self.items.data, self.mark)
  of bRec:
    initRec(self.items.data, self.mark)
  of bDict:
    initDict(self.dict.copy, self.mark)
  of bSet:
    initSet(self.els.copy, self.mark)

# ================ Misc converstion fns ================

func `'bn`*(n: string, mark = false): Value =
  num(n, mark)

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