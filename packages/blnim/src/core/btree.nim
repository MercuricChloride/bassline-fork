##[
  A simple b+ tree

  The surface area here is likely going to change, but conceptually
  this is used as a lighter "nim-native" version of what's going
  on in the store.
]##
import std/algorithm

const
  M {.intdefine.} = 64
  ## max children per internal node. 
  ## 64 seems to be a good sweet spot
  maxKeys = M - 1

type
  NodeKind = enum
    nkLeaf, nkInternal
  Node[K, V] {.acyclic.} = ref object
    keys: seq[K]
    case kind: NodeKind
    of nkLeaf:
      vals: seq[V]
      next: Node[K, V]
    of nkInternal:
      kids: seq[Node[K, V]]

  BTree*[K, V] = object
    entries: int
    root: Node[K, V]

func initBTree*[K, V](): BTree[K, V] =
  BTree[K, V](root: Node[K, V](kind: nkLeaf))

func len*[K, V](t: BTree[K, V]): int =
  t.entries

func leafFor[K, V](t: BTree[K, V], key: K): Node[K, V] =
  ## The leaf whose key range covers `key`
  result = t.root
  while result != nil and result.kind == nkInternal:
    result = result.kids[upperBound(result.keys, key)]

func contains*[K, V](t: BTree[K, V], key: K): bool =
  let leaf = t.leafFor(key)
  if leaf == nil: return false
  let i = lowerBound(leaf.keys, key)
  i < leaf.keys.len and leaf.keys[i] == key

func `[]`*[K, V](t: BTree[K, V], key: K): V =
  let leaf = t.leafFor(key)
  if leaf != nil:
    let i = lowerBound(leaf.keys, key)
    if i < leaf.keys.len and leaf.keys[i] == key:
      return leaf.vals[i]
  raise newException(KeyError, "key not found")

proc put[K, V](node: Node[K, V], key: K, val: V, grew: var bool):
    tuple[sep: K, right: Node[K, V]] =
  ## Inserts under `node`. When the insert overflows `node` it splits:
  ## the new right half comes back with the separator key to file in
  ## the parent. `right` is nil when no split happened
  case node.kind
  of nkLeaf:
    let i = lowerBound(node.keys, key)
    if i < node.keys.len and node.keys[i] == key:
      node.vals[i] = val
      return
    grew = true
    node.keys.insert(key, i)
    node.vals.insert(val, i)
    if node.keys.len > maxKeys:
      let h = node.keys.len div 2
      let right = Node[K, V](kind: nkLeaf,
        keys: node.keys[h .. ^1], vals: node.vals[h .. ^1], next: node.next)
      node.keys.setLen(h)
      node.vals.setLen(h)
      node.next = right
      result = (right.keys[0], right)
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

iterator pairs*[K, V](t: BTree[K, V]): (K, V) =
  ## All entries in key order, walking the leaf chain.
  var leaf = t.root
  if leaf != nil:
    while leaf.kind == nkInternal:
      leaf = leaf.kids[0]
    while leaf != nil:
      for i in 0 ..< leaf.keys.len:
        yield (leaf.keys[i], leaf.vals[i])
      leaf = leaf.next

iterator pairsFrom*[K, V](t: BTree[K, V], lo: K): (K, V) =
  ## Entries with key >= lo, in key order.
  var leaf = t.leafFor(lo)
  if leaf != nil:
    var i = lowerBound(leaf.keys, lo)
    while leaf != nil:
      while i < leaf.keys.len:
        yield (leaf.keys[i], leaf.vals[i])
        inc i
      leaf = leaf.next
      i = 0

iterator items*[K, V](t: Btree[K, V]): V =
  for _, v in t.pairs:
    yield v

iterator itemsFrom*[K, V](t: BTree[K, V], lo: K): V =
  for _, v in t.pairsFrom(lo):
    yield v

func entries*[K, V](t: BTree[K, V]): iterator: (K, V) {.closure.} =
  for k, v in t:
    yield (k, v)

func merge*[K, V](t: var BTree[K, V], other: BTree[K, V]) =
  for k, v in other:
    t[k] = v