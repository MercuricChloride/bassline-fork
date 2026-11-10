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

  FramePart* = object
    val*: Value
    case
    of El: discard
    of Pair:
      key*: Value
    of Slot:
      slot*: int

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

# ================
# Live
# ================

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

# ================
# Node
# ================

func isFrame*(self: Node): bool =
  self.kind in {bList..bSet}

func isFrame*(self: Value): bool =
  case self
  of Data(n): n.isFrame
  else: false

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
    for v in a.vseq:
      yield v
  of bDict:
    for k,v in a.vdict:
      yield k
      yield v
  of bSet:
    for v in a.vset:
      yield v
  else: discard

iterator mChildFrames(self: var Node): var Node =
  case self.kind
  of bList, bRec:
    for each in self.vseq.mitems:
      if each.isFrame:
        yield each.asNode
  of bDict:
    for entry in self.vdict.entries.mitems:
      if entry.key.isFrame:
        yield entry.key.asNode
      if entry.val.isFrame:
        yield entry.val.asNode
  of bSet:
    for each in self.vset.data.mitems:
      if each.isFrame:
        yield each.asNode
  else: discard

iterator mframes*(self: var Node): var Node {.closure.} =
  if self.isFrame:
    yield self
    for each in self.mChildFrames:
      for deep in each.mframes:
        yield deep

iterator parts*(a: Node): FramePart =
  case a.kind
  of bList, bRec:
    for i,v in a.vseq:
      yield Slot(slot: i, val: v)
  of bDict:
    for k,v in a.vdict:
      yield Pair(key: k, val: v)
  of bSet:
    for v in a.vset:
      yield El(val: v)
  else: discard

iterator takeParts*(a: sink Node): FramePart =
  ## resets `a`'s internal state so that we can 
  ## use `a`.add with the new parts to update it
  case a.kind
  of bList, bRec:
    for i,v in a.vseq.mpairs:
      yield Slot(slot: i, val: move v)
  of bDict:
    var entries = move a.vdict.entries
    a.vdict.entries.setLen(0)
    for entry in entries.mitems:
      yield Pair(key: move(entry.key), val: move(entry.val))
  of bSet:
    var els = move a.vset.data
    a.vset.data.setLen(0)
    for entry in els.mitems:
      yield El(val: move entry)
  else: discard

func apply*(a: var Node, parts: varargs[FramePart]) =
  for p in parts:
    case p
    of Pair(k):
      guard a.kind == bDict, "must apply pair to dict"
      a.vdict.insert(k, p.val)
    of Slot(i):
      guard a.kind in {bList, bRec}, "must apply a slot to list / rec"
      guard i in 0..<a.vseq.len, "slot out of bounds"
      a.vseq[i] = p.val
    of El:
      guard a.kind == bSet, "must apply El to set: " & $a.kind
      a.vset.incl p.val

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

func len*(a: Value): int =
  case a
  of Data(n): n.len
  else: 0

iterator parts*(a: Value): FramePart =
  case a
  of Data(a):
    for part in a.parts:
      yield part
  else: discard

iterator children*(self: Value): lent Value =
  case self
  of Data(a):
    for each in a.children:
      yield each
  else: discard

iterator walk*(self: Value): lent Value {.closure.} =
  ## post order walk over self
  yield self
  for child in self.children:
    for each in child.walk:
      yield each

func hash*(self: Value): Hash =
  case self
  of Bound(a): a.hash
  of Data:
    var h: Hash
    for each in self.walk:
      case each
      of Bound(a):
        h = h !& a.hash
      of Data(a):
        h = h !& a.kind.hash
        h = h !& a.mark.hash
        case a.kind
        of bNum:
          h = h !& a.vnum.hash
        of bText,bSym,bBytes:
          h = h !& a.vstr.hash
        else: discard
    !$ h

# ================
# Reification
# ================

func isPureData*(a: Value): bool =
  for each in a.walk:
    if each.isLive: return false
  true

func reify*(self: sink Value): Value

func reify*(self: sink Node): Value =
  if self.isFrame: 
    var changes = newSeqofCap[FramePart](self.len)
    for p in self.takeParts:
      var part = p
      case part
      of Pair(k):
        k = k.reify
      else: discard
      part.val = part.val.reify
      changes.add part
    self.apply changes
  self.toValue

func reify*(self: sink Value): Value =
  case self
  of Data(n): n.reify
  of Bound(l): l.reify.reify

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

proc writeReified(n: sink Node, enc: var Enc) =
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
      each.write(enc)
    enc.writeClose

proc write*(self: sink Value, enc: var Enc) =
  case self.reify
  of Data(n): n.writeReified(enc)
  of Bound: refuse "should never reach"

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
  decode("decode value " & $size & "MB")