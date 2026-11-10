import std/hashes
import bigints
import ./[ce, types]

refuseWith BasslineError

type
  Value* = object
    case
    of Data:
      data*: Node
    of Bound:
      live*: Live

  Node* = object
    mark*: bool
    case kind*: Kind
    of bNil: discard
    of bNum: 
      vnum*: BNum
    of bText, bSym, bBytes:
      vstr*: string
    of bList, bRec:
      vseq*: seq[Value]
    of bDict:
      vdict*: SortedTable[Value, Value]
    of bSet:
      vset*: SortedSet[Value]

  Live* = ref object of RootObj
  Send* = ref object of Live
  Search* = ref object of Live

  ValueBuilder* = object

const BuildValue* = ValueBuilder()

func toValue*(self: sink Node): Value =
  Data(data: self)

func toValue*(self: Live): Value =
  Bound(live: self)

# ================
# Live methods
# ================

method reify*(self: Live): Node {.base, raises: [BasslineError].} =
  refuse "reify must be implemented!"

method send*(self: Send, val: sink Value): bool {.base, raises: [].} =
  false

method search*(self: Search, val: sink Value): (iterator: Value) {.base, raises: [].} =
  iterator: Value = discard

func hash*(self: Live): Hash =
  hash cast[pointer](self)

func cmp*(a,b: Live): int =
  cmp(cast[int](a), cast[int](b))

func `<`*(a,b: Live): bool =
  cmp(a,b) < 0

func `<=`*(a,b: Live): bool =
  a == b or a < b

func `==`*(a,b: Live): bool =
  cmp(a,b) == 0

func isLive*(self: Value): bool =
  case self
  of Bound: true
  else: false

func asLive*(self: Value): Live =
  case self
  of Bound(v): v
  else: refuse("not live")

func isNode*(self: Value): bool =
  not self.isLive

func asNode*(self: Value): lent Node =
  case self
  of Data(n): 
    return n
  else: refuse("not data")

func asNode*(self: var Value): var Node =
  case self
  of Data(n):
    return n
  else: refuse "not data"

func node*(self: sink Value): Node =
  case self
  of Data(n): n
  of Bound(l): l.reify

func isFrame*(self: Node): bool =
  self.kind in {bList..bSet}

func len*(a: Node): int =
  case a.kind
  of bList, bRec:
    a.vseq.len
  of bDict:
    a.vdict.len
  of bSet:
    a.vset.len
  else: 0

func getChild*(a: Node, i: int): lent Value =
  case a.kind
  of bList, bRec:
    return a.vseq[i]
  of bDict:
    return a.vdict.getRavel(i)
  of bSet:
    return a.vset.data[i]
  else: refuse("not a frame")

func cmp*(a,b: Value): int
func `==`*(a,b: Value): bool
func `<`*(a,b: Value): bool

func cmp*(a,b: Node): int =
  template `??`(x,y) =
    let r = cmp(x,y)
    if r != 0: return r

  a.kind ?? b.kind
  a.mark ?? b.mark

  case a.kind
  of bNil: 0
  of bNum:
    cmpNums(a.vnum, b.vnum)
  of bText, bSym, bBytes:
    cmpShortlex(a.vstr, b.vstr)
  of bList,bRec,bDict,bSet:
    for i in 0 ..< min(a.len, b.len):
      a.getChild(i) ?? b.getChild(i)
    cmp(b.len, a.len)

func `==`*(a,b: Node): bool =
  cmp(a,b) == 0

func `<`*(a,b: Node): bool =
  cmp(a,b) < 0

func `<=`*(a,b:Node): bool =
  cmp(a,b) <= 0

iterator children*(a: Node): lent Value =
  case a.kind
  of bList, bRec:
    for i in 0 ..< a.vseq.len:
      yield a.vseq[i]
  of bDict:
    for i in 0 ..< a.vdict.entries.len:
      yield a.vdict.entries[i].key
      yield a.vdict.entries[i].val
  of bSet:
    for i in 0 ..< a.vset.data.len:
      yield a.vset.data[i]
  else: discard

# ================
# Value
# ================

func cmp*(a,b: Value): int =
  case a
  of Bound(a):
    case b
    of Data: 1
    of Bound(b):
      cmp(cast[int](a), cast[int](b))
  of Data(a):
    case b
    of Bound: -1
    of Data(b):
      cmp(a, b)

func `<`*(a,b: Value): bool =
  cmp(a,b) < 0

func `<=`*(a,b: Value): bool =
  cmp(a,b) <= 0

func `==`*(a,b: Value): bool =
  cmp(a,b) == 0

func hash*(self: Value): Hash

func hash*(self: Node): Hash =
  var h = self.kind.hash !& self.mark.hash
  case self.kind
  of bNil: discard
  of bNum:
    h = h !& self.vnum.hash
  of bText, bSym, bBytes:
    h = h !& self.vstr.hash
  else:
    for each in self.children:
      h = h !& each.hash
  !$h

func hash*(self: Value): Hash =
  if self.isLive: self.asLive.hash
  else: self.asNode.hash

# ================
# Reification
# ================

func isPureData*(a: Value): bool

func isPureData*(n: Node): bool =
  for each in n.children:
    if not each.isPureData: return false
  true

func isPureData*(a: Value): bool =
  a.isNode and a.asNode.isPureData

func reifyIn(self: var Value): bool

func reifyIn(self: var Node): bool =
  case self.kind
  of bList, bRec:
    for i in 0 ..< self.vseq.len:
      if self.vseq[i].reifyIn: result = true
  of bSet:
    for i in 0 ..< self.vset.data.len:
      if self.vset.data[i].reifyIn: result = true
    if result:
      var members = move self.vset.data
      self.vset.data.setLen 0
      for m in members.mitems:
        self.vset.incl move m
  of bDict:
    for i in 0 ..< self.vdict.entries.len:
      if self.vdict.entries[i].key.reifyIn: result = true
      if self.vdict.entries[i].val.reifyIn: result = true
    if result:
      var entries = move self.vdict.entries
      self.vdict.entries.setLen 0
      for e in entries.mitems:
        self.vdict.insert(move e.key, move e.val)
  else: discard

func reifyIn(self: var Value): bool =
  if self.isLive:
    self = self.asLive.reify.toValue
    discard self.asNode.reifyIn
    true
  else:
    self.asNode.reifyIn

func reify*(self: sink Node): Node =
  discard self.reifyIn
  self

func reify*(self: sink Value): Node =
  self.node.reify

# ================
# Builder
# ================

using
  mark: bool
  kind: Kind

proc null*(_: ValueBuilder, mark): Value =
  Data(data: Node(kind: bNil, mark: mark))

proc atom*(_: ValueBuilder, s: sink string, kind, mark): Value =
  case kind
  of bNum:
    Data(data: Node(kind: kind, mark: mark, vnum: initNum(s)))
  of bText, bSym, bBytes:
    Data(data: Node(kind: kind, mark: mark, vstr: s))
  else:
    refuse "not an atom"

proc frame*(_: ValueBuilder, s: sink seq[Value], kind, mark): Value =
  case kind:
  of bDict:
    Data(data: Node(kind: bDict, mark: mark, vdict: fromRavel(s)))
  of bSet:
    Data(data: Node(kind: bSet, mark: mark, vset: s.toSortedSet))
  of bRec:
    guard s.len > 0, "record missing head"
    Data(data: Node(kind: bRec, mark: mark, vseq: s))
  of bList:
    Data(data: Node(kind: bList, mark: mark, vseq: s))
  else: refuse("not a frame")

# ================
# Enc
# ================

proc writeReified(n: Node, enc: var Enc) =
  case n.kind
  of bNil: 
    enc.writeNull(n.mark)
  of bNum: 
    enc.writeAtom(n.kind, n.mark, $n.vnum)
  of bText,bSym,bBytes:
    enc.writeAtom(n.kind, n.mark, n.vstr)
  else:
    enc.writeOpen(n.kind, n.mark)
    for each in n.children:
      each.asNode.writeReified(enc)
    enc.writeClose

proc write*(self: sink Value, enc: var Enc) =
  self.reify.writeReified(enc)

when isMainModule:
  import std/[monotimes, times, strutils]

  # the jam, whole, through both types
  let 
    jam = readFile("/Users/goose/prg/jordans-bl/jams/jam.blb").repeat(50)
    size = jam.len / 1_000_000

  proc decode(label: string) =
    var best = float.high
    for _ in 0..<7:
      var reader = initReader(BuildValue)
      let t0 = getMonoTime()
      for _ in reader.readEach(jam):
        discard
      best = min(best, (getMonoTime() - t0).inNanoseconds.float / 1e6)
    echo label, ": ", best, " ms"

  proc encode(label: string) =
    var
      best = float.high
      s = ""
      r = initReader(BuildValue)
      values: seq[Value] = @[]
    for each in r.readEach(jam):
      values.add each 
    for _ in 0..<7:
      s.setLen(0)
      let elements = BuildValue.frame(values, bList, false)
      let t0 = getMonoTime()
      elements.write(s)
      best = min(best, (getMonoTime() - t0).inNanoseconds.float / 1e6)
    echo label, ": ", best, " ms"

  decode("decode value " & $size & "MB")
  encode("encode value " & $size & "MB")