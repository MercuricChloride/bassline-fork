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

  Node {.acyclic.} = ref NodeObj

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

func kind*(self: Memo): Kind =
  self.node.kind
func mark*(self: Memo): bool =
  self.mark
func numVal*(self: Memo): lent BNum =
  self.node.num

template getter(name) =
  func name*(self: Memo): lent string =
    self.node.payload

getter textVal
getter symVal
getter bytesVal

func len*(self: Memo): int =
  self.node[].width
func getChild*(self: Memo, i: int): lent Memo =
  self.node[].at(i)

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
# BVal
# ================

# the checks values.nim makes, in the same words, for a Memo and a Draft


func contains*(self: Memo, x: Memo): bool =
  ## whether a dict has x as a key, or a set as a member, found by bisecting
  case self.kind
  of bDict:
    x in self.node.dict
  of bSet:
    x in self.node.els
  else:
    refuse("only a dict or a set has keys")

func getNum*(self: Memo): lent BNum =
  self.expectKind(numeric)
  self.node.num

func getText*(self: Memo): lent string =
  self.expectKind(textual)
  self.node.payload

func getBytes*(self: Memo): lent string =
  self.expectKind(bBytes)
  self.node.payload

func slotLen*(self: Memo): int =
  ## how many slots a list or a record has, 0 for anything else
  if self.kind in {bList, bRec}: self.node.items.len else: 0

func getSlot*(self: Memo, i: int): lent Memo =
  ## a list's or a record's slot at i
  self.expectKind(slotted)
  self.expectSlot(i)
  self.node.items[i]

func keyLen*(self: Memo): int =
  ## how many keys a dict or a set has, 0 for anything else
  case self.kind
  of bDict: self.node.dict.len
  of bSet: self.node.els.len
  else: 0

func getKey*(self, key: Memo): lent Memo =
  ## a dict's value for key, found by bisecting its keys
  self.expectKind(bDict)
  let i = self.node.dict.indexOf(key)
  guard i != -1, "the dict has no such key"
  self.node.dict.vals[i]

func keyAt*(self: Memo, i: int): lent Memo =
  ## a dict's key or a set's member at rank i, in CE order
  self.expectKind(keyed)
  if self.kind == bDict:
    return self.node.dict.keys[i]
  return self.node.els.data[i]

func valueAt*(self: Memo, i: int): lent Memo =
  ## a dict's value under the key at rank i
  self.expectKind(bDict)
  self.node.dict.vals[i]

func rankOf*(self, key: Memo): int =
  ## key's rank among a dict's keys or a set's members, found by
  ## bisecting, -1 when it is absent
  case self.kind
  of bDict: self.node.dict.indexOf(key)
  of bSet: self.node.els.indexOf(key)
  else: refuse "only a dict or a set has keys"

iterator getItems*(self: Memo): lent Memo =
  ## a list's or a record's slots in order, or a set's or a dict's keys
  ## in CE order
  case self.kind
  of bList, bRec:
    for m in self.node.items:
      yield m
  of bSet:
    for m in self.node.els:
      yield m
  of bDict:
    for k in self.node.dict.keys:
      yield k
  else:
    refuse "only a frame has items"

iterator getSlots*(self: Memo): tuple[pos: int, val: Memo] =
  ## a list's or a record's slots with their positions
  guard self.kind in {bList, bRec}, "only a list or a record has slots"
  for i, m in self.node.items:
    yield (i, m)

iterator getPairs*(self: Memo): tuple[key, val: Memo] =
  ## a dict's keys and values, in CE order of the keys
  guard self.kind == bDict, "only a dict has keys and values"
  for i in 0 ..< self.node.dict.len:
    yield (self.node.dict.keys[i], self.node.dict.vals[i])

iterator getKeys*(self: Memo): lent Memo =
  ## a dict's keys or a set's members, in CE order
  case self.kind
  of bDict:
    for k in self.node.dict.keys:
      yield k
  of bSet:
    for m in self.node.els:
      yield m
  else:
    refuse "only a dict or a set has keys"

iterator getValues*(self: Memo): lent Memo =
  ## a dict's values, in CE order of their keys
  guard self.kind == bDict, "only a dict has values"
  for v in self.node.dict.vals:
    yield v

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
# Keeping edited frames
# ================
# A Memo never changes. An edit block builds the one frame its draft
# makes, in the cache the edited value is kept in, and points the handle
# there, so every other handle holds what it held. The frame's members are
# shared, and a member from another cache is brought in. The frame is
# hashed and kept just as `buildFrame` keeps it, so an edited value is the
# node the same value read anew would be. Its order isn't checked again,
# since an edit keeps it.

proc setMark*(self: var Memo, mark: bool) =
  self.mark = mark

func sameMembers(a, b: openArray[Memo]): bool =
  ## whether a and b hold one node with one mark at every place
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i].node != b[i].node or a[i].mark != b[i].mark:
      return false
  true

func mixMember(h: var Hash, m: Memo) =
  ## m mixed into a frame's hash as buildFrame mixes each member
  h = h !& m.node.hash !& hash(m.mark)

proc keptSlots(c: Cache, k: bList .. bRec, s: sink seq[Memo], mark: bool): Memo =
  ## the list or record of s, c's members in order
  var h = hash(k)
  for m in s:
    h.mixMember m
  h = !$h
  Memo(
    node: c.kept(
      h, n, n.kind == k and n.items.sameMembers(s), Node(kind: k, hash: h, cache: c, items: s)
    ),
    mark: mark,
  )

proc keptDict(c: Cache, d: sink SortedTable[Memo, Memo], mark: bool): Memo =
  ## the dict of d, c's keys and values in CE order of the keys
  var h = hash(bDict)
  for k, v in d:
    h.mixMember k
    h.mixMember v
  h = !$h
  Memo(
    node: c.kept(
      h,
      n,
      n.kind == bDict and n.dict.keys.sameMembers(d.keys) and
        n.dict.vals.sameMembers(d.vals),
      Node(kind: bDict, hash: h, cache: c, dict: d),
    ),
    mark: mark,
  )

proc keptSet(c: Cache, e: sink SortedSet[Memo], mark: bool): Memo =
  ## the set of e, c's members in CE order
  var h = hash(bSet)
  for m in e:
    h.mixMember m
  h = !$h
  Memo(
    node: c.kept(
      h,
      n,
      n.kind == bSet and n.els.data.sameMembers(e.data),
      Node(kind: bSet, hash: h, cache: c, els: e),
    ),
    mark: mark,
  )

# ================
# Drafts
# ================
# A Memo's draft: a frame's members held apart from the value drafted,
# in the containers a node holds them in, edited with their own procs. A
# list's or a record's are a seq in order, a dict's a SortedTable and a
# set's a SortedSet, which keep CE order themselves. `toMemo` builds the
# value it makes once, in the cache the value drafted is kept in, and
# refuses a record left without a head.

type Draft* = object
  ## A Memo open to edits. The value drafted is left as it was
  cache: Cache
  mark*: bool
  case kind: Kind
  of bNil .. bBytes:
    atom: Memo
  of bList, bRec:
    items*: seq[Memo]
  of bDict:
    dict*: SortedTable[Memo, Memo]
  of bSet:
    els*: SortedSet[Memo]

func kind*(d: Draft): Kind =
  d.kind

proc draft*(v: Memo): Draft =
  ## v opened for edits, kept apart from v
  let n = v.node
  case n.kind
  of bNil .. bBytes:
    let k: bNil .. bBytes = n.kind
    Draft(cache: n.cache, mark: v.mark, kind: k, atom: v)
  of bList, bRec:
    let k: bList .. bRec = n.kind
    Draft(cache: n.cache, mark: v.mark, kind: k, items: n.items)
  of bDict:
    Draft(cache: n.cache, mark: v.mark, kind: bDict, dict: n.dict)
  of bSet:
    Draft(cache: n.cache, mark: v.mark, kind: bSet, els: n.els)

proc broughtIn(c: Cache, s: var seq[Memo]) =
  ## s's members from another cache brought into c, sharing one import so
  ## what they share is brought once
  var seen = default(Table[pointer, Node])
  for m in s.mitems:
    if m.node.cache != c:
      m.node = c.brought(m.node, seen)

func allIn(s: openArray[Memo], c: Cache): bool =
  ## whether s's members are all c's
  for m in s:
    if m.node.cache != c:
      return false
  true

proc toMemo*(d: sink Draft): Memo =
  ## the value d makes, kept in the cache d was drafted from, a member
  ## from another cache brought in
  let c = d.cache
  case d.kind
  of bNil .. bBytes:
    result = move d.atom
    result.mark = d.mark
  of bList, bRec:
    guard d.kind == bList or d.items.len > 0, "a record keeps its head"
    c.broughtIn(d.items)
    result = c.keptSlots(d.kind, move d.items, d.mark)
  of bDict:
    if d.dict.keys.allIn(c) and d.dict.vals.allIn(c):
      result = c.keptDict(move d.dict, d.mark)
    else:
      var s = newSeqOfCap[Memo](2 * d.dict.len)
      for k, v in d.dict:
        s.add k
        s.add v
      result = c.buildFrame(move s, bDict, d.mark)
  of bSet:
    if d.els.data.allIn(c):
      result = c.keptSet(move d.els, d.mark)
    else:
      result = c.buildFrame(d.els.data, bSet, d.mark)

# ================
# Misc
# ================

proc memoize*[T: Walkable](c: Cache, self: sink T): Memo =
  case self.kind
  of bNil: c.buildNull(self.mark)
  of bNum: c.buildAtom(self.numStr, bNum, self.mark)
  of bText: c.buildAtom(self.textVal, bText, self.mark)
  of bSym: c.buildAtom(self.symVal, bSym, self.mark)
  of bBytes: c.buildAtom(self.bytesVal, bBytes, self.mark)
  else:
    var items = newSeqOfCap[Memo](self.len)
    for i in 0 ..< self.len:
      items.add c.memoize(self.getChild(i))
    c.buildFrame(move items, self.kind, self.mark)

proc memoize*[T: Walkable](self: sink T): Memo =
  globalCache().memoize(self)


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
  d.expectKind(slotted)
  d.items[i]

proc `[]`*(d: var Draft, i: BackwardsIndex): var Memo =
  d.expectKind(slotted)
  d.items[d.items.len - i.int]

proc `[]`*(d: var Draft, key: Memo): var Memo =
  ## the value under key, to edit where it stands
  d.expectKind(bDict)
  d.dict[key]

proc `[]=`*(d: var Draft, i: int, x: sink Memo) =
  d.expectKind(slotted)
  d.items[i] = x

proc `[]=`*(d: var Draft, i: BackwardsIndex, x: sink Memo) =
  d.expectKind(slotted)
  d.items[d.items.len - i.int] = x

proc `[]=`*(d: var Draft, key, val: sink Memo) =
  d.expectKind(bDict)
  d.dict[key] = val

proc add*(d: var Draft, x: sink Memo) =
  d.expectKind(slotted)
  d.items.add x

proc insert*(d: var Draft, x: sink Memo, i = 0) =
  d.expectKind(slotted)
  d.items.insert(x, i)

proc delete*(d: var Draft, i: int) =
  ## takes out the member at i, keeping the others in order
  d.expectKind(slotted)
  d.items.delete(i)

proc del*(d: var Draft, key: Memo) =
  ## takes out key and its value, if the dict has it
  d.expectKind(bDict)
  d.dict.delete(key)

proc incl*(d: var Draft, x: sink Memo) =
  d.expectKind(bSet)
  d.els.incl x

proc excl*(d: var Draft, x: Memo) =
  d.expectKind(bSet)
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