import std/[strutils, hashes]
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

# ================
# Node
# ================

func isNode*(self: Value): bool =
  not self.isLive

func asNode*(self: Value): Node =
  case self
  of Data(n): n
  else: refuse("not data")

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

iterator children*(a: Value): Value =
  case a
  of Data(a):
    case a.kind
    of bList, bRec:
      for each in a.vseq:
        yield each
    of bDict:
      for k,v in a.vdict:
        yield k; yield v
    of bSet:
      for each in a.vseq:
        yield each
    else: discard
  else: discard

iterator walk*(self: Value): Value {.closure.} =
  yield self
  for child in self.children:
    for each in child.walk:
      yield each

iterator living*(self: Value): Live =
  for each in self.walk:
    case each
    of Bound(v): yield v
    else: discard

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

when isMainModule:
  import std/[monotimes, times]

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