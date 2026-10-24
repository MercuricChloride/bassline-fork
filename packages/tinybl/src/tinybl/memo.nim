import std/[hashes, sets, tables]
import ./[ce, text, values]
export tables

refuseWith BasslineError

type
  NodeObj {.byref.} = object
    hash: Hash
      ## from the kind and payload, or the kind and the members' hashes and
      ## marks in CE order, whichever way the frame holds them
    cache: Cache
      ## the cache the node is kept in, held so it lives as long as its nodes
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

  Cache* = ref object
    ## Where Memos are kept. Equal values built in one cache are one node,
    ## and a frame built in it from another cache's values holds them as
    ## its own. A node leaves when the last value holding it goes, and the
    ## cache lives until it and its last node are gone. A cache and its
    ## values stay on the thread that made them.
    nodes: Table[Hash, seq[ptr NodeObj]]

var global {.threadvar.}: Cache

proc newCache*(): Cache =
  Cache()

proc globalCache*(): Cache =
  ## this thread's cache, the one a Memo builds itself in
  if global.isNil:
    global = newCache()
  global

proc len*(c: Cache): int =
  ## how many nodes c holds
  for bucket in c.nodes.values:
    result += bucket.len

proc cached*(): int =
  ## how many nodes this thread's cache holds
  globalCache().len

proc `=copy`(a: var NodeObj, b: NodeObj) {.error.}

proc `=destroy`(x: NodeObj) {.raises: [].} =
  ## a node leaves its cache, then lets go of its parts and the cache
  if not x.cache.isNil:
    var emptied = false
    x.cache.nodes.withValue(x.hash, bucket):
      for i in 0 ..< bucket[].len:
        if bucket[][i] == addr x:
          bucket[].del i
          break
      emptied = bucket[].len == 0
    if emptied:
      x.cache.nodes.del x.hash
  {.cast(raises: []).}:
    case x.kind
    of bNil:
      discard
    of bNum:
      `=destroy`((addr x)[].num)
    of bText .. bBytes:
      `=destroy`(x.payload)
    of bList, bRec:
      `=destroy`(x.items)
    of bDict:
      `=destroy`((addr x)[].dict)
    of bSet:
      `=destroy`((addr x)[].els)
    `=destroy`((addr x)[].cache)

template kept(c: Cache, h: Hash, n, fits, made: untyped): Node =
  ## the node c keeps under h that fits, or else made, and kept
  var
    bucket = addr c.nodes.mgetOrPut(h, @[])
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
  of bList, bRec:
    n.items.len
  of bDict:
    2 * n.dict.len
  of bSet:
    n.els.len
  else:
    0

func at(n: NodeObj, i: int): lent Memo =
  ## n's member at i in CE order, a dict's keys and values alternating
  case n.kind
  of bList, bRec:
    return n.items[i]
  of bDict:
    (
      if i mod 2 == 0:
        return n.dict.keys[i div 2]
      else:
        return n.dict.vals[i div 2]
    )
  of bSet:
    return n.els.data[i]
  else:
    refuse("only a frame has members")

iterator members(n: NodeObj): lent Memo =
  case n.kind
  of bList, bRec:
    for m in n.items:
      yield m
  of bDict:
    for i in 0 ..< n.dict.len:
      yield n.dict.keys[i]
      yield n.dict.vals[i]
  of bSet:
    for m in n.els:
      yield m
  else:
    discard

func holds(n: NodeObj, s: seq[Memo]): bool =
  ## whether n's members are s, member for member. Members are kept
  ## before their frame, so equal members share nodes
  if n.width != s.len:
    return false
  var i = 0
  for m in n.members:
    if m.node != s[i].node or m.mark != s[i].mark:
      return false
    inc i
  true

# ================
# Walkable
# ================

func valid*(self: Memo): bool =
  true
func kind*(self: Memo): Kind =
  self.node.kind
func mark*(self: Memo): bool =
  self.mark
func payload*(self: Memo): lent string =
  self.node.payload
func digits*(self: Memo): string =
  $self.node.num
func num*(self: Memo): lent BNum =
  self.node.num
func cmpNums*(a, b: Memo): int =
  cmpNums(a.node.num, b.node.num)
func len*(self: Memo): int =
  self.node[].width
func getChild*(self: Memo, i: int): lent Memo =
  self.node[].at(i)

iterator children*(self: Memo): lent Memo =
  for m in self.node[].members:
    yield m

func sameContents*(a, b: Memo): bool =
  ## whether a and b are one node, so hold the same contents
  a.node == b.node

func hash*(self: Memo): Hash =
  !$(self.node.hash !& hash(self.mark))

# ================
# Comparison
# ================
# In one cache equal values are one node, so two nodes are equal only if
# they are one. Across caches equal values are different nodes with the
# same hash, and a value can share a node along many paths, so a pair of
# nodes found equal is remembered for the rest of the comparison rather
# than walked again wherever it recurs.

type Equal = HashSet[(pointer, pointer)]

func same(a, b: Node, equal: var Equal): bool =
  ## whether a and b hold the same contents
  if a == b:
    return true
  if a.cache == b.cache or a.hash != b.hash or a.kind != b.kind:
    return false
  let pair = (cast[pointer](a), cast[pointer](b))
  if pair in equal:
    return true
  case a.kind
  of bNil:
    discard
  of bNum:
    if a.num != b.num:
      return false
  of bText .. bBytes:
    if a.payload != b.payload:
      return false
  of bList .. bSet:
    let n = a[].width
    if n != b[].width:
      return false
    for i in 0 ..< n:
      let (x, y) = (a[].at(i), b[].at(i))
      if x.mark != y.mark or not same(x.node, y.node, equal):
        return false
  equal.incl pair
  true

func order(a, b: Memo, equal: var Equal): int =
  ## CE order: kind, then mark, then shortlex for atoms, then members,
  ## a frame sorting after a longer one it prefixes
  result = cmp(a.kind, b.kind)
  if result != 0:
    return
  result = cmp(a.mark, b.mark)
  if result != 0 or same(a.node, b.node, equal):
    return
  case a.kind
  of bNil:
    discard
  of bNum:
    result = cmpNums(a.node.num, b.node.num)
  of bText .. bBytes:
    result = cmpShortlex(a.node.payload, b.node.payload)
  of bList .. bSet:
    for i in 0 ..< min(a.len, b.len):
      result = order(a.getChild(i), b.getChild(i), equal)
      if result != 0:
        return
    result = cmp(b.len, a.len)

func cmp*(a, b: Memo): int =
  var equal = default(Equal)
  order(a, b, equal)

func `==`*(a, b: Memo): bool =
  var equal = default(Equal)
  a.mark == b.mark and same(a.node, b.node, equal)

func `<`*(a, b: Memo): bool =
  cmp(a, b) < 0

func `<=`*(a, b: Memo): bool =
  cmp(a, b) <= 0

makePrintable(Memo)

# ================
# Access
# ================

func `[]`*(self: Memo, key: Memo): lent Memo =
  ## a dict's value for key, found by bisecting its keys
  guard self.kind == bDict, "only a dict has values for keys"
  self.node.dict.get(key)

func contains*(self: Memo, x: Memo): bool =
  ## whether a dict has x as a key, or a set as a member, found by bisecting
  case self.kind
  of bDict:
    x in self.node.dict
  of bSet:
    x in self.node.els
  else:
    refuse("only a dict or a set is searched")

# ================
# Builder
# ================

proc buildNull*(c: Cache, mark: bool): Memo =
  let h = hash(bNil)
  Memo(node: c.kept(h, n, n.kind == bNil, Node(kind: bNil, hash: h, cache: c)), mark: mark)

proc buildAtom*(c: Cache, s: sink string, kind: Kind, mark: bool): Memo =
  let k: bNum .. bBytes = kind
  case k
  of bNum:
    guard isValidInt(s), "invalid integer"
  of bText, bSym:
    guard isValidUtf8(s), "invalid utf8 bytes"
  of bBytes:
    discard
  let h = !$(hash(k) !& hash(s))
  case k
  of bNum:
    let v = initNum(s)
    Memo(
      node: c.kept(
        h, n, n.kind == bNum and n.num == v, Node(kind: bNum, hash: h, cache: c, num: v)
      ),
      mark: mark,
    )
  of bText .. bBytes:
    Memo(
      node: c.kept(
        h, n, n.kind == k and n.payload == s, Node(kind: k, hash: h, cache: c, payload: s)
      ),
      mark: mark,
    )

proc made(c: Cache, k: bList .. bSet, h: Hash, s: sink seq[Memo]): Node =
  ## a frame's node, its members c's and already in CE order
  case k
  of bList, bRec:
    Node(kind: k, hash: h, cache: c, items: s)
  of bDict:
    var
      keys = newSeqOfCap[Memo](s.len div 2)
      vals = newSeqOfCap[Memo](s.len div 2)
    for i in countup(0, s.len - 1, 2):
      keys.add move s[i]
      vals.add move s[i + 1]
    Node(
      kind: bDict,
      hash: h,
      cache: c,
      dict: toSortedTable(move keys, move vals, sorted = true),
    )
  of bSet:
    Node(kind: bSet, hash: h, cache: c, els: toSortedSet(s, sorted = true))

proc brought(c: Cache, n: Node, seen: var Table[pointer, Node]): Node =
  ## n's node in c, each node's hash kept. seen holds what this import has
  ## brought so far, so a node shared within n is brought once
  if n.cache == c:
    return n
  seen.withValue(cast[pointer](n), found):
    return found[]
  let h = n.hash
  case n.kind
  of bNil:
    result = c.kept(h, x, x.kind == bNil, Node(kind: bNil, hash: h, cache: c))
  of bNum:
    result = c.kept(
      h, x, x.kind == bNum and x.num == n.num, Node(kind: bNum, hash: h, cache: c, num: n.num)
    )
  of bText .. bBytes:
    let k: bText .. bBytes = n.kind
    result = c.kept(
      h,
      x,
      x.kind == k and x.payload == n.payload,
      Node(kind: k, hash: h, cache: c, payload: n.payload),
    )
  of bList .. bSet:
    let k: bList .. bSet = n.kind
    var s = newSeqOfCap[Memo](n[].width)
    for each in n[].members:
      s.add Memo(node: c.brought(each.node, seen), mark: each.mark)
    result = c.kept(h, x, x.kind == k and x[].holds(s), c.made(k, h, s))
  seen[cast[pointer](n)] = result

proc memoize*(c: Cache, m: Memo): Memo =
  ## m as c holds it: m itself when its nodes are c's, otherwise the same
  ## value made of c's nodes, each of m's nodes visited once
  if m.node.cache == c:
    return m
  var seen = default(Table[pointer, Node])
  Memo(node: c.brought(m.node, seen), mark: m.mark)

proc buildFrame*(c: Cache, s: sink seq[Memo], kind: Kind, mark: bool): Memo =
  let k: bList .. bSet = kind
  # members from another cache are brought in, sharing one import so what
  # they share is brought once
  var seen = default(Table[pointer, Node])
  for m in s.mitems:
    if m.node.cache != c:
      m.node = c.brought(m.node, seen)
  case k
  of bList:
    discard
  of bRec:
    guard s.len > 0, "record must have a head"
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
  Memo(node: c.kept(h, n, n.kind == k and n[].holds(s), c.made(k, h, s)), mark: mark)

proc buildNull*(T: typedesc[Memo], mark: bool): Memo =
  globalCache().buildNull(mark)

proc buildAtom*(T: typedesc[Memo], s: sink string, kind: Kind, mark: bool): Memo =
  globalCache().buildAtom(s, kind, mark)

proc buildFrame*(T: typedesc[Memo], s: sink seq[Memo], kind: Kind, mark: bool): Memo =
  globalCache().buildFrame(s, kind, mark)

# ================
# Editable
# ================

proc setMark*(self: var Memo, mark: bool) =
  self.mark = mark

# ================
# Edits
# ================
# A Memo never changes. An edit builds a new value in the cache the
# edited value is kept in, then points the handle it was given there, so
# every other handle holds what it held before. Members from another
# cache are brought in. `edit` makes many edits and builds once.

type Draft* = object
  ## A frame's members open to edits: a list's or record's members in
  ## order, a dict's entries or a set's members in CE order. `toMemo`
  ## builds the value they make, leaving the value drafted as it was
  cache: Cache
  mark: bool
  case kind: Kind
  of bList, bRec:
    items: seq[Memo]
  of bDict:
    dict: SortedTable[Memo, Memo]
  of bSet:
    els: SortedSet[Memo]
  else:
    discard

proc draft*(v: Memo): Draft =
  ## v's members, kept apart from v, to edit and build anew
  let n = v.node
  case n.kind
  of bList, bRec:
    let k: bList .. bRec = n.kind
    Draft(cache: n.cache, mark: v.mark, kind: k, items: n.items)
  of bDict:
    Draft(cache: n.cache, mark: v.mark, kind: bDict, dict: n.dict)
  of bSet:
    Draft(cache: n.cache, mark: v.mark, kind: bSet, els: n.els)
  else:
    refuse("only a frame has members to edit")

proc toMemo*(d: sink Draft): Memo =
  ## the value d's members make, kept in the cache d was drafted from
  case d.kind
  of bList, bRec:
    d.cache.buildFrame(move d.items, d.kind, d.mark)
  of bDict:
    var s = newSeqOfCap[Memo](2 * d.dict.len)
    for i in 0 ..< d.dict.len:
      s.add d.dict.keys[i]
      s.add d.dict.vals[i]
    d.cache.buildFrame(move s, bDict, d.mark)
  of bSet:
    d.cache.buildFrame(d.els.data, bSet, d.mark)
  else:
    refuse("only a frame has members to edit")

template positional(d: Draft) =
  guard d.kind in {bList, bRec}, "only a list or a record is edited by position"

template keyed(d: Draft) =
  guard d.kind == bDict, "only a dict is edited by key"

template membered(d: Draft) =
  guard d.kind == bSet, "only a set has members put in or taken out"

func len*(d: Draft): int =
  case d.kind
  of bList, bRec: d.items.len
  of bDict: d.dict.len
  of bSet: d.els.len
  else: 0

func contains*(d: Draft, x: Memo): bool =
  ## whether a dict draft has x as a key, or a set draft as a member
  case d.kind
  of bDict:
    x in d.dict
  of bSet:
    x in d.els
  else:
    refuse("only a dict or a set is searched")

proc `[]`*(d: var Draft, i: int): var Memo =
  ## the member at i, to edit where it stands
  d.positional
  d.items[i]

proc `[]`*(d: var Draft, i: BackwardsIndex): var Memo =
  d.positional
  d.items[d.items.len - i.int]

proc `[]`*(d: var Draft, key: Memo): var Memo =
  ## the value under key, to edit where it stands
  d.keyed
  d.dict[key]

proc `[]=`*(d: var Draft, i: int, x: sink Memo) =
  d.positional
  d.items[i] = x

proc `[]=`*(d: var Draft, i: BackwardsIndex, x: sink Memo) =
  d.positional
  d.items[d.items.len - i.int] = x

proc `[]=`*(d: var Draft, key, val: sink Memo) =
  d.keyed
  d.dict[key] = val

proc add*(d: var Draft, x: sink Memo) =
  d.positional
  d.items.add x

proc insert*(d: var Draft, x: sink Memo, i = 0) =
  d.positional
  d.items.insert(x, i)

proc delete*(d: var Draft, i: int) =
  ## takes out the member at i, keeping the others in order
  d.positional
  d.items.delete(i)

proc del*(d: var Draft, key: Memo) =
  ## takes out key and its value, if the dict has it
  d.keyed
  d.dict.delete(key)

proc incl*(d: var Draft, x: sink Memo) =
  d.membered
  d.els.incl x

proc excl*(d: var Draft, x: Memo) =
  d.membered
  d.els.excl x

template edit*(v: var Memo, body: untyped) =
  ## edits a draft of v's members as `it`, then points v at the value they
  ## make, built once. If body or the build refuses, v is left as it was.
  ## v is found once, as a var parameter is, so what body does to an index
  ## in it doesn't move the edit, and body mustn't move what holds v
  block:
    let target = addr v
    var it {.inject.} = draft(target[])
    body
    target[] = toMemo(move it)

template edited*(v: Memo, body: untyped): Memo =
  ## the value v would be after body, edited as in `edit`, v left as it is
  block:
    var it {.inject.} = draft(v)
    body
    toMemo(move it)

func `[]`*(self: Memo, i: BackwardsIndex): lent Memo =
  self.getChild(self.len - i.int)

proc `[]=`*(v: var Memo, i: int, x: sink Memo) =
  v.edit:
    it[i] = x

proc `[]=`*(v: var Memo, i: BackwardsIndex, x: sink Memo) =
  v.edit:
    it[i] = x

proc `[]=`*(v: var Memo, key, val: sink Memo) =
  v.edit:
    it[key] = val

proc add*(v: var Memo, x: sink Memo) =
  v.edit:
    it.add x

proc insert*(v: var Memo, x: sink Memo, i = 0) =
  v.edit:
    it.insert(x, i)

proc delete*(v: var Memo, i: int) =
  v.edit:
    it.delete i

proc del*(v: var Memo, key: Memo) =
  v.edit:
    it.del key

proc incl*(v: var Memo, x: sink Memo) =
  v.edit:
    it.incl x

proc excl*(v: var Memo, x: Memo) =
  v.edit:
    it.excl x

# ================
# Misc
# ================

proc memoize*[T: Walkable](c: Cache, self: sink T): Memo =
  case self.kind
  of bNil: c.buildNull(self.mark)
  of bNum: c.buildAtom(self.digits, bNum, self.mark)
  of bText..bBytes: c.buildAtom(self.payload, self.kind, self.mark)
  else: 
    var items = newSeqOfCap[Memo](self.len)
    for each in self.children:
      items.add c.memoize(each)
    c.buildFrame(move items, self.kind, self.mark)

proc memoize*[T: Walkable](self: sink T): Memo =
  globalCache().memoize(self)