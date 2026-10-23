import std/[hashes, tables]
import ./[ce, text, values]

refuseWith BasslineError

type
  NodeObj {.byref.} = object
    hash: Hash
      ## from the kind and payload, or the kind and the members' hashes and
      ## marks in CE order, whichever way the frame holds them
    case kind: Kind
    of bNil: discard
    of bNum: num: BNum
    of bText .. bBytes: payload: string
    of bList, bRec: items: seq[Memo]
    of bDict: dict: SortedTable[Memo, Memo]
    of bSet: els: SortedSet[Memo]
  Node = ref NodeObj
  Memo* = object
    node: Node
    mark: bool

var cache {.threadvar.}: Table[Hash, seq[ptr NodeObj]]

proc `=copy`(a: var NodeObj, b: NodeObj) {.error.}

proc `=destroy`(x: NodeObj) {.raises: [].} =
  ## a node leaves the cache, then lets go of its parts
  var emptied = false
  cache.withValue(x.hash, bucket):
    for i in 0 ..< bucket[].len:
      if bucket[][i] == addr x:
        bucket[].del i
        break
    emptied = bucket[].len == 0
  if emptied: cache.del x.hash
  {.cast(raises: []).}:
    case x.kind
    of bNil: discard
    of bNum: `=destroy`((addr x)[].num)
    of bText .. bBytes: `=destroy`(x.payload)
    of bList, bRec: `=destroy`(x.items)
    of bDict: `=destroy`((addr x)[].dict)
    of bSet: `=destroy`((addr x)[].els)

proc cached*(): int =
  ## how many nodes this thread's cache holds
  for bucket in cache.values:
    result += bucket.len

template kept(h: Hash, n, fits, made: untyped): Node =
  ## the node kept under h that fits, or else made, and kept
  var
    bucket = addr cache.mgetOrPut(h, @[])
    found: Node
  for i in 0 ..< bucket[].len:
    let n = bucket[][i]
    if fits:
      # copied out of a place, so the new reference is counted
      found = cast[ptr Node](addr bucket[][i])[]
      break
  if found.isNil:
    found = made
    bucket[].add cast[ptr NodeObj](found)
  found

# ================
# Members, whichever way a frame holds them
# ================

func width(n: NodeObj): int =
  ## how many members n has in CE, a dict's keys and values each counted
  case n.kind
  of bList, bRec: n.items.len
  of bDict: 2 * n.dict.len
  of bSet: n.els.len
  else: 0

func at(n: NodeObj, i: int): lent Memo =
  ## n's member at i in CE order, a dict's keys and values alternating
  case n.kind
  of bList, bRec: 
    return n.items[i]
  of bDict: (if i mod 2 == 0: 
    return n.dict.keys[i div 2] 
  else: 
    return n.dict.vals[i div 2])
  of bSet: 
    return n.els.data[i]
  else: refuse("only a frame has members")

iterator members(n: NodeObj): lent Memo =
  case n.kind
  of bList, bRec:
    for m in n.items: yield m
  of bDict:
    for i in 0 ..< n.dict.len:
      yield n.dict.keys[i]
      yield n.dict.vals[i]
  of bSet:
    for m in n.els: yield m
  else: discard

func holds(n: NodeObj, s: seq[Memo]): bool =
  ## whether n's members are s, member for member. Members are kept
  ## before their frame, so equal members share nodes
  if n.width != s.len: return false
  var i = 0
  for m in n.members:
    if m.node != s[i].node or m.mark != s[i].mark: return false
    inc i
  true

# ================
# Walkable
# ================

func valid*(self: Memo): bool = true
func kind*(self: Memo): Kind = self.node.kind
func mark*(self: Memo): bool = self.mark
func payload*(self: Memo): lent string = self.node.payload
func digits*(self: Memo): string = $self.node.num
func num*(self: Memo): lent BNum = self.node.num
func cmpNums*(a, b: Memo): int = cmpNums(a.node.num, b.node.num)
func len*(self: Memo): int = self.node[].width
func getChild*(self: Memo, i: int): lent Memo = self.node[].at(i)

iterator children*(self: Memo): lent Memo =
  for m in self.node[].members:
    yield m

func sameContents*(a, b: Memo): bool =
  ## whether a and b are one node, so hold the same contents
  a.node == b.node

func hash*(self: Memo): Hash = !$(self.node.hash !& hash(self.mark))

makeCmp(Memo)
makePrintable(Memo)

# ================
# Access
# ================

func `[]`*(self: Memo, i: int): lent Memo =
  ## a list's or record's member at i
  guard self.kind in {bList, bRec}, "only a list or a record is indexed"
  self.node.items[i]

func `[]`*(self: Memo, key: Memo): lent Memo =
  ## a dict's value for key, found by bisecting its keys
  guard self.kind == bDict, "only a dict has values for keys"
  self.node.dict.get(key)

func contains*(self: Memo, x: Memo): bool =
  ## whether a dict has x as a key, or a set as a member, found by bisecting
  case self.kind
  of bDict: x in self.node.dict
  of bSet: x in self.node.els
  else: refuse("only a dict or a set is searched")

# ================
# Readable
# ================

proc null*(T: typedesc[Memo], mark: bool): Memo =
  let h = hash(bNil)
  Memo(node: kept(h, n, n.kind == bNil, Node(kind: bNil, hash: h)), mark: mark)

proc atom*(T: typedesc[Memo], s: sink string, kind: Kind, mark: bool): Memo =
  let k: bNum .. bBytes = kind
  case k
  of bNum: guard isValidInt(s), "invalid integer"
  of bText, bSym: guard isValidUtf8(s), "invalid utf8 bytes"
  of bBytes: discard
  let h = !$(hash(k) !& hash(s))
  case k
  of bNum:
    let v = initNum(s)
    Memo(node: kept(h, n, n.kind == bNum and n.num == v, Node(kind: bNum, hash: h, num: v)), mark: mark)
  of bText .. bBytes:
    Memo(
      node: kept(h, n, n.kind == k and n.payload == s, Node(kind: k, hash: h, payload: s)),
      mark: mark,
    )

proc made(k: bList .. bSet, h: Hash, s: sink seq[Memo]): Node =
  ## a frame's node, its members already in CE order
  case k
  of bList, bRec:
    Node(kind: k, hash: h, items: s)
  of bDict:
    var
      keys = newSeqOfCap[Memo](s.len div 2)
      vals = newSeqOfCap[Memo](s.len div 2)
    for i in countup(0, s.len - 1, 2):
      keys.add move s[i]
      vals.add move s[i + 1]
    Node(kind: bDict, hash: h, dict: toSortedTable(move keys, move vals, sorted = true))
  of bSet:
    Node(kind: bSet, hash: h, els: toSortedSet(s, sorted = true))

proc frame*(T: typedesc[Memo], s: sink seq[Memo], kind: Kind, mark: bool): Memo =
  let k: bList .. bSet = kind
  case k
  of bList: discard
  of bRec: guard s.len > 0, "record must have a head"
  of bDict:
    guard s.len mod 2 == 0, "dict cannot have stranded keys"
    for i in countup(2, s.len - 1, 2):
      guard s[i - 2] < s[i], "dict keys must be strictly ascending"
  of bSet:
    for i in 1 ..< s.len:
      guard s[i - 1] < s[i], "set elements must be strictly ascending"
  var mixed = hash(k)
  for m in s:
    mixed = mixed !& m.node.hash !& hash(m.mark)
  let h = !$mixed
  Memo(node: kept(h, n, n.kind == k and n[].holds(s), made(k, h, s)), mark: mark)

# ================
# Editable
# ================

proc setMark*(self: var Memo, mark: bool) =
  self.mark = mark