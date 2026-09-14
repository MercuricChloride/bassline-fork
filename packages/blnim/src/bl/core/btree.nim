import std/algorithm

const
  M {.intdefine.} = 64
  ## max children per internal node
  maxKeys = M - 1

type
  Entry*[K, V] = tuple[key: K, val: V]
  Pair*[T] = Entry[T, T]

  NodeKind = enum
    nkLeaf, nkInternal

  Node[K, V] {.acyclic.} = ref object
    case kind: NodeKind
    of nkLeaf:
      entries: seq[Entry[K, V]]
      # we use a single seq so iteration can lend entries
      next: Node[K, V]
    of nkInternal:
      keys: seq[K]
      # separators: kids[i] < keys[i] <= kids[i+1]
      kids: seq[Node[K, V]]

  BTree*[K, V] {.acyclic.} = ref object
    entries: int
    root: Node[K, V]

  BTreeSet*[T] {.acyclic.} = ref object
    entries: int
    root: Node[T, bool]

# ================ Nodes ================

func lowerIdx[K, V](entries: openArray[Entry[K, V]], key: K): int =
  ## first index whose key is >= key
  var lo = 0
  var hi = entries.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if cmp(entries[mid].key, key) < 0: lo = mid + 1
    else: hi = mid
  lo

func leafFor[K, V](root: Node[K, V], key: K): Node[K, V] =
  ## The leaf whose key range covers `key`
  result = root
  while result != nil and result.kind == nkInternal:
    result = result.kids[upperBound(result.keys, key)]

func contains[K, V](root: Node[K, V], key: K): bool =
  let leaf = root.leafFor(key)
  if leaf == nil: return false
  let i = lowerIdx(leaf.entries, key)
  i < leaf.entries.len and cmp(leaf.entries[i].key, key) == 0

func find[K, V](node: Node[K, V], key: K): lent V =
  case node.kind
  of nkLeaf:
    let i = lowerIdx(node.entries, key)
    if i < node.entries.len and cmp(node.entries[i].key, key) == 0:
      return node.entries[i].val
    raise newException(KeyError, "key not found")
  of nkInternal:
    return find(node.kids[upperBound(node.keys, key)], key)

proc put[K, V](node: Node[K, V], key: K, val: V, grew: var bool):
    tuple[sep: K, right: Node[K, V]] =
  ## Inserts under `node`. When the insert overflows `node` it splits:
  ## the new right half comes back with the separator key to file in
  ## the parent. `right` is nil when no split happened
  case node.kind
  of nkLeaf:
    let i = lowerIdx(node.entries, key)
    if i < node.entries.len and cmp(node.entries[i].key, key) == 0:
      node.entries[i].val = val
      return
    grew = true
    node.entries.insert((key, val), i)
    if node.entries.len > maxKeys:
      let h = node.entries.len div 2
      let right = Node[K, V](kind: nkLeaf,
        entries: node.entries[h .. ^1], next: node.next)
      node.entries.setLen(h)
      node.next = right
      result = (right.entries[0].key, right)
  of nkInternal:
    let at = upperBound(node.keys, key)
    let (sep, right) = put(node.kids[at], key, val, grew)
    if right != nil:
      node.keys.insert(sep, at)
      node.kids.insert(right, at + 1)
      if node.keys.len > maxKeys:
        let h = node.keys.len div 2
        let split = Node[K, V](kind: nkInternal,
          keys: node.keys[h + 1 .. ^1], kids: node.kids[h + 1 .. ^1])
        result = (node.keys[h], split)
        node.keys.setLen(h)
        node.kids.setLen(h + 1)

func firstLeaf[K, V](root: Node[K, V]): Node[K, V] =
  ## the leftmost leaf, or nil when the tree is empty
  result = root
  if result != nil:
    while result.kind == nkInternal:
      result = result.kids[0]
    if result.entries.len == 0:
      result = nil

func low[K, V](node: Node[K, V]): lent K =
  ## smallest key under `node`
  case node.kind
  of nkLeaf:     return node.entries[0].key
  of nkInternal: return low(node.kids[0])

func high[K, V](node: Node[K, V]): lent K =
  ## largest key under `node`
  case node.kind
  of nkLeaf:     return node.entries[node.entries.len - 1].key
  of nkInternal: return high(node.kids[node.kids.len - 1])

iterator pairs*[K, V](root: Node[K, V]): lent Entry[K, V] =
  var leaf = root.firstLeaf
  while leaf != nil:
    for i in 0 ..< leaf.entries.len:
      yield leaf.entries[i]
    leaf = leaf.next

iterator pairsFrom[K, V](root: Node[K, V], lo: K): lent Entry[K, V] =
  let leaf = root.leafFor(lo)
  for entry in leaf.pairs:
    if entry.key < lo: continue
    yield entry

iterator pairsFrom[K, V](root: Node[K, V], lo, hi: K): lent Entry[K, V] =
  ## yields all between lo..hi inclusive
  for entry in root.pairsFrom(lo):
    if entry.key > hi: break
    yield entry

iterator keys[K, V](root: Node[K, V]): lent K =
  for k, _ in root:
    yield k

iterator lockstep[K, V](a, b: Node[K, V]):
    (lent Entry[K, V], lent Entry[K, V]) =
  var la = a.firstLeaf
  var lb = b.firstLeaf
  var ia = 0
  var ib = 0
  while la != nil and lb != nil:
    yield (la.entries[ia], lb.entries[ib])
    inc ia
    if ia >= la.entries.len:
      la = la.next
      ia = 0
    inc ib
    if ib >= lb.entries.len:
      lb = lb.next
      ib = 0

# ================ BTree ================

func newBTree*[K, V](): BTree[K, V] =
  BTree[K, V](root: Node[K, V](kind: nkLeaf))

func newBTreeSet*[T](): BTreeSet[T] =
  BTreeSet[T](root: Node[T, bool](kind: nkLeaf))

proc toBTree*[K, V](pairs: openArray[(K,V)]): BTree[K, V] =
  result = newBTree[K,V]()
  for (k, v) in pairs:
    result[k] = v

proc toBTreeSet*[T](items: openArray[T]): BTreeSet[T] =
  result = newBTreeSet[T]()
  for item in items:
    result.incl item

func len*[K, V](t: BTree[K, V]): int =
  t.entries

func contains*[K, V](t: BTree[K, V], k: K): bool =
  k in t.root

func `[]`*[K, V](t: BTree[K, V], key: K): lent V =
  if t.root == nil:
    raise newException(KeyError, "key not found")
  return find(t.root, key)

proc `[]=`*[K, V](t: BTree[K, V], key: K, val: V) =
  if t.root == nil:
    t.root = Node[K, V](kind: nkLeaf)
  var grew = false
  let (sep, right) = put(t.root, key, val, grew)
  if right != nil:
    t.root = Node[K, V](kind: nkInternal, keys: @[sep], kids: @[t.root, right])
  if grew:
    inc t.entries
func low*[K, V](t: BTree[K, V]): lent K =
  ## The smallest key. Raises `KeyError` on an empty tree.
  if t == nil or t.root == nil or t.entries == 0:
    raise newException(KeyError, "low on an empty btree")
  return low(t.root)

func high*[K, V](t: BTree[K, V]): lent K =
  ## The largest key. Raises `KeyError` on an empty tree.
  if t == nil or t.root == nil or t.entries == 0:
    raise newException(KeyError, "high on an empty btree")
  return high(t.root)

iterator items*[K, V](t: BTree[K, V]): lent V =
  for _, v in pairs(t.root): yield v

iterator pairs*[K, V](t: BTree[K, V]): lent Entry[K, V] =
  for e in pairs(t.root): yield e

iterator keys*[K, V](t: BTree[K, V]): lent K =
  for e in keys(t.root): yield e

proc keys*[K, V](t: BTree[K, V]): BTreeSet[K] =
  result = newBTreeSet[K]()
  for k, _ in t:
    result.incl k

proc values*[K, V](t: BTree[K, V]): BTreeSet[V] =
  result = newBTreeSet[V]()
  for _, v in t:
    result.incl v

iterator pairsFrom*[K, V](t: BTree[K, V], lo: K): lent Entry[K, V] =
  ## entries with key >= lo
  for e in t.root.pairsFrom(lo): yield e

iterator pairsFrom*[K, V](t: BTree[K, V], lo, hi: K): lent Entry[K, V] =
  ## entries with hi >= key >= lo
  for e in t.root.pairsFrom(lo, hi): yield e

iterator lockstep*[K, V](a, b: BTree[K, V]):
    (lent Entry[K, V], lent Entry[K, V]) =
  ## Both trees in key order, entry by entry, for as long as both have entries
  for (x, y) in lockstep(a.root, b.root):
    yield (x, y)

proc map*[C,D](
    t: BTree, fn: proc(k: t.K, v: t.V): Entry[C, D]
    ): BTree[C,D] =
  result = newBTree[C,D]()
  for k,v in t:
    let (key, val) = fn(k, v)
    result[key] = val

proc filter*(
    t: BTree, fn: proc(k: t.K, v: t.V): bool
  ): BTree[t.K,t.V] =
  result = newBTree[t.K,t.V]()
  for k,v in t:
    if fn(k,v):
      result[k] = v

proc reduce*[A](
    t: BTree, init: A, fn: proc(acc: A, k: t.K, v: t.V): A
  ): A =
  result = init
  for k, v in t:
    result = fn(result, k, v)

proc union*[K, V](a, b: BTree[K, V]): BTree[K, V] =
  result = newBTree[K, V]()
  for k, v in a:
    result[k] = v
  for k, v in b:
    result[k] = v

proc difference*[K, V](a, b: BTree[K, V]): BTree[K, V] =
  result = newBTree[K, V]()
  for k, v in a:
    if k notin b:
      result[k] = v

proc intersection*[K, V](a, b: BTree[K, V]): BTree[K, V] =
  result = newBTree[K, V]()
  let
    (smaller, larger) = if a.len < b.len: (a, b) else: (b, a)
  for k in keys(smaller):
    if k in larger: 
      result[k] = b[k]

proc select*(self: BTree, keys: BTreeSet[self.K]): auto =
  result = newBTree[self.K, self.V]()
  for k in keys:
    result[k] = self[k]

proc `+`*[K, V](a, b: BTree[K, V]): BTree[K, V] =
  ## alias for union
  union a, b

proc `-`*[K, V](a, b: BTree[K, V]): BTree[K, V] =
  ## alias for difference
  difference a, b

proc `*`*[K, V](a, b: BTree[K, V]): BTree[K, V] =
  ## alias for intersection
  intersection a, b

proc `/`*(self: BTree, keys: BTreeSet[self.K]): auto =
  ## alias for select
  select self, keys

func disjoint*(a, b: BTree): bool =
  let (smaller, larger) = if a.len < b.len: (a, b) else: (b, a)
  for k in smaller.keys:
    if k in larger: return false
  return true

func `<=`*(a, b: BTree): bool =
  ## Returns true if `a` is a sub(set?) of `b`
  if a.len > b.len: return
  result = true
  let (smaller, larger) = if a.len < b.len: (a, b) else: (b, a)
  for k, v in smaller:
    if v notin larger or (v != larger[k]):
      return false

func `<`*(a, b: BTree): bool =
  ## Returns true if `a` is a strict and proper subset of `b`
  (a.len != b.len) and a <= b

func `==`*(a, b: BTree): bool =
  if not(a.isNil) and not(b.isNil):
    a.len == b.len and a <= b
  elif a.isNil and b.isNil:
    true
  else:
    false

# ================ BTreeSet ================

func len*[T](t: BTreeSet[T]): int =
  t.entries

func contains*[T](t: BTreeSet[T], val: T): bool =
  val in t.root

proc incl*[T](t: BTreeSet[T], val: T) =
  if t.root == nil:
    t.root = Node[T, bool](kind: nkLeaf)
  var grew = false
  let (sep, right) = put(t.root, val, true, grew)
  if right != nil:
    t.root = Node[T, bool](kind: nkInternal, keys: @[sep], kids: @[t.root, right])
  if grew:
    inc t.entries

proc union*[T](a, b: BTreeSet[T]): BTreeSet[T] =
  result = newBTreeSet[T]()
  for v in a:
    incl(result, v)
  for v in b:
    incl(result, v)

proc difference*[T](a, b: BTreeSet[T]): BTreeSet[T] =
  result = newBTreeSet[T]()
  for v in a:
    if v notin b:
      incl(result, v)

proc intersection*[T](a, b: BTreeSet[T]): BTreeSet[T] =
  result = newBTreeSet[T]()
  let
    (smaller, larger) = if a.len < b.len: (a, b) else: (b, a)
  for v in smaller:
    if v in larger: incl(result, v)

proc `+`*[T](a, b: BTreeSet[T]): BTreeSet[T] =
  ## alias for union
  union a, b

proc `-`*[T](a, b: BTreeSet[T]): BTreeSet[T] =
  ## alias for difference
  difference a, b

proc `*`*[T](a, b: BTreeSet[T]): BTreeSet[T] =
  ## alias for intersection
  intersection a, b

func `<=`*(a, b: BTreeSet): bool =
  ## Returns true if `a` is a subset of `b`
  if a.len > b.len: return
  result = true
  for v in a:
    if v notin b:
      return false

func `<`*(a, b: BTreeSet): bool =
  ## Returns true if `a` is a strict and proper subset of `b`
  (a.len != b.len) and a <= b

func `==`*(a, b: BTreeSet): bool =
  if not(a.isNil) and not(b.isNil):
    a.len == b.len and a <= b
  elif a.isNil and b.isNil:
    true
  else:
    false

func disjoint*(a, b: BTreeSet): bool =
  let (smaller, larger) = if a.len < b.len: (a, b) else: (b, a)
  for item in smaller:
    if item in larger: return false
  return true

func low*[T](t: BTreeSet[T]): lent T =
  ## The smallest key. Raises `KeyError` on an empty tree.
  if t == nil or t.root == nil or t.entries == 0:
    raise newException(KeyError, "low on an empty btree")
  return low(t.root)

func high*[T](t: BTreeSet[T]): lent T =
  ## The largest key. Raises `KeyError` on an empty tree.
  if t == nil or t.root == nil or t.entries == 0:
    raise newException(KeyError, "high on an empty btree")
  return high(t.root)

proc reduce*[A, T](
    t: BTreeSet[T], init: A,
    fn: proc(acc: A, curr: T): A
  ): A =
  result = init
  for item in t:
    result = fn(result, item)

proc map*[T, K](
    t: BTreeSet[T], fn: proc(item: T): K
  ): BTreeSet[K] =
  result = newBTreeSet[K]()
  for item in t:
    result.incl fn(item)

proc filter*[T](
    t: BTreeSet[T], fn: proc(item: T): bool
  ): BTreeSet[T] =
  result = newBTreeSet[T]()
  for item in t:
    if fn(item):
      result.incl item

iterator items*[T](t: BTreeSet[T]): lent T =
  for v, _ in t.root:
    yield v

iterator itemsFrom*[T](t: BTreeSet[T], lo: T): lent T =
  ## entries with key >= lo
  for v, _ in pairsFrom(t.root, lo):
    yield v

iterator itemsFrom*[T](t: BTreeSet[T], lo, hi: T): lent T =
  ## entries with hi >= key >= lo
  for v, _ in pairsFrom(t.root, lo, hi): 
    yield v

iterator lockstep*[T](a, b: BTreeSet[T]):
    (lent T, lent T) =
  ## Both trees in key order, entry by entry, for as long as both have entries
  for (x, y) in lockstep(a.root, b.root):
    yield (x.key, y.key)