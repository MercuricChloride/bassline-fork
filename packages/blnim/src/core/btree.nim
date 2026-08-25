import std/algorithm

const
  M {.intdefine.} = 64
  ## max children per internal node
  maxKeys = M - 1

type
  Entry*[K, V] = tuple[key: K, val: V]
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

  BTree*[K, V] = object
    entries: int
    root: Node[K, V]

func initBTree*[K, V](): BTree[K, V] =
  BTree[K, V](root: Node[K, V](kind: nkLeaf))

func len*[K, V](t: BTree[K, V]): int =
  t.entries

func lowerIdx[K, V](entries: openArray[Entry[K, V]], key: K): int =
  ## first index whose key is >= key
  var lo = 0
  var hi = entries.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if cmp(entries[mid].key, key) < 0: lo = mid + 1
    else: hi = mid
  lo

func leafFor[K, V](t: BTree[K, V], key: K): Node[K, V] =
  ## The leaf whose key range covers `key`
  result = t.root
  while result != nil and result.kind == nkInternal:
    result = result.kids[upperBound(result.keys, key)]

func contains*[K, V](t: BTree[K, V], key: K): bool =
  let leaf = t.leafFor(key)
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

func `[]`*[K, V](t: BTree[K, V], key: K): lent V =
  if t.root == nil:
    raise newException(KeyError, "key not found")
  return find(t.root, key)

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

proc `[]=`*[K, V](t: var BTree[K, V], key: K, val: V) =
  if t.root == nil:
    t.root = Node[K, V](kind: nkLeaf)
  var grew = false
  let (sep, right) = put(t.root, key, val, grew)
  if right != nil:
    t.root = Node[K, V](kind: nkInternal, keys: @[sep], kids: @[t.root, right])
  if grew:
    inc t.entries

func firstLeaf[K, V](t: BTree[K, V]): Node[K, V] =
  ## the leftmost leaf, or nil when the tree is empty
  result = t.root
  if result != nil:
    while result.kind == nkInternal:
      result = result.kids[0]
    if result.entries.len == 0:       # only a root leaf can be empty
      result = nil

iterator pairs*[K, V](t: BTree[K, V]): lent Entry[K, V] =
  var leaf = t.firstLeaf
  while leaf != nil:
    for i in 0 ..< leaf.entries.len:
      yield leaf.entries[i]
    leaf = leaf.next

iterator pairsFrom*[K, V](t: BTree[K, V], lo: K): lent Entry[K, V] =
  ## Entries with key >= lo
  var leaf = t.leafFor(lo)
  if leaf != nil:
    var i = lowerIdx(leaf.entries, lo)
    while leaf != nil:
      while i < leaf.entries.len:
        yield leaf.entries[i]
        inc i
      leaf = leaf.next
      i = 0

iterator keys*[K, V](t: BTree[K, V]): lent K =
  var leaf = t.firstLeaf
  while leaf != nil:
    for i in 0 ..< leaf.entries.len:
      yield leaf.entries[i].key
    leaf = leaf.next

iterator items*[K, V](t: BTree[K, V]): lent V =
  var leaf = t.firstLeaf
  while leaf != nil:
    for i in 0 ..< leaf.entries.len:
      yield leaf.entries[i].val
    leaf = leaf.next

iterator itemsFrom*[K, V](t: BTree[K, V], lo: K): lent V =
  for e in t.pairsFrom(lo):
    yield e.val

iterator lockstep*[K, V](a, b: BTree[K, V]):
    (lent Entry[K, V], lent Entry[K, V]) =
  ## Both trees in key order, entry by entry, for as long as both have entries
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

proc merge*[K, V](t: var BTree[K, V], other: BTree[K, V]) =
  for k, v in other:
    t[k] = v