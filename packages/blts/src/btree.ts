const M = 32 // max keys per node

type Cmp<T> = (a: T, b: T) => number

class Leaf<K, V> {
  keys: K[] = []
  vals: V[] = []
  next: Leaf<K, V> | null = null
  constructor() {}
}

class Branch<K, V> {
  keys: K[] = []
  kids: (Leaf<K, V> | Branch<K, V>)[] = []
}

type Node<K, V> = Leaf<K, V> | Branch<K, V>

function lowerBound<K>(keys: K[], key: K, cmp: Cmp<K>): number {
  let lo = 0
  let hi = keys.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (cmp(keys[mid]!, key) < 0) lo = mid + 1
    else hi = mid
  }
  return lo
}

function upperBound<K>(keys: K[], key: K, cmp: Cmp<K>): number {
  let lo = 0
  let hi = keys.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (cmp(keys[mid]!, key) <= 0) lo = mid + 1
    else hi = mid
  }
  return lo
}

export class BTree<K, V> {
  #cmp: Cmp<K>
  #root: Node<K, V> = new Leaf<K, V>()
  #size = 0
  constructor(compare: Cmp<K>, entries?: Iterable<[K, V]>) {
    this.#cmp = compare
    if (entries) for (const [k, v] of entries) this.set(k, v)
  }

  get size() {
    return this.#size
  }

  get cmp() {
    return this.#cmp
  }

  get(key: K) {
    const { leaf } = this.#descend(key)
    const i = lowerBound(leaf.keys, key, this.#cmp)
    return i < leaf.keys.length && this.#cmp(leaf.keys[i]!, key) === 0
      ? leaf.vals[i]
      : undefined
  }

  has(key: K) {
    const { leaf } = this.#descend(key)
    const i = lowerBound(leaf.keys, key, this.#cmp)
    return i < leaf.keys.length && this.#cmp(leaf.keys[i]!, key) === 0
  }

  set(key: K, value: V) {
    const { leaf, path } = this.#descend(key)
    const i = lowerBound(leaf.keys, key, this.#cmp)
    if (i < leaf.keys.length && this.#cmp(leaf.keys[i]!, key) === 0) {
      leaf.vals[i] = value
      return this
    }
    leaf.keys.splice(i, 0, key)
    leaf.vals.splice(i, 0, value)
    this.#size++
    if (leaf.keys.length > M) this.#splitLeaf(leaf, path)
    return this
  }

  #descend(key: K) {
    let node = this.#root
    const path: [Branch<K, V>, number][] = []
    while (node instanceof Branch) {
      const i = upperBound(node.keys, key, this.#cmp)
      path.push([node, i])
      node = node.kids[i]!
    }
    return { leaf: node, path }
  }

  #splitLeaf(leaf: Leaf<K, V>, path: [Branch<K, V>, number][]) {
    const mid = leaf.keys.length >> 1
    const right = new Leaf<K, V>()
    right.keys = leaf.keys.splice(mid)
    right.vals = leaf.vals.splice(mid)
    right.next = leaf.next
    leaf.next = right
    this.#insertUp(path, right.keys[0]!, right)
  }

  #insertUp(path: [Branch<K, V>, number][], sep: K, right: Node<K, V>) {
    if (path.length === 0) {
      const root = new Branch<K, V>()
      root.keys = [sep]
      root.kids = [this.#root, right]
      this.#root = root
      return
    }
    const [branch, i] = path.pop()!
    branch.keys.splice(i, 0, sep)
    branch.kids.splice(i + 1, 0, right)
    if (branch.keys.length > M) {
      const mid = branch.keys.length >> 1
      const up = branch.keys[mid]! // the middle key moves up, not copied
      const rb = new Branch<K, V>()
      rb.keys = branch.keys.splice(mid + 1)
      rb.kids = branch.kids.splice(mid + 1)
      branch.keys.splice(mid) // drop the promoted key
      this.#insertUp(path, up, rb)
    }
  }

  #firstLeaf() {
    let n = this.#root
    while (n instanceof Branch) n = n.kids[0]!
    return n
  }

  *entries() {
    for (let l: Leaf<K, V> | null = this.#firstLeaf(); l !== null; l = l.next) {
      for (let i = 0; i < l.keys.length; i++) {
        yield [l.keys[i], l.vals[i]] as [K, V]
      }
    }
  }

  [Symbol.iterator]() {
    return this.entries()
  }

  *keys() {
    for (const [k, v] of this) yield k
  }

  *values() {
    for (const [k, v] of this) yield v
  }

  clone() {
    return new BTree<K, V>(this.cmp, this)
  }
}

export class BTreeSet<T> {
  #tree: BTree<T, true>
  constructor(cmp: Cmp<T>, values?: Iterable<T>) {
    this.#tree = new BTree<T, true>(cmp)
    if (values) for (const each of values) this.#tree.set(each, true)
  }

  get size() {
    return this.#tree.size
  }

  add(item: T) {
    this.#tree.set(item, true)
  }

  has(item: T) {
    return this.#tree.has(item)
  }

  *values() {
    yield* this.#tree.keys()
  }

  [Symbol.iterator]() {
    return this.values()
  }

  clone() {
    return new BTreeSet<T>(this.#tree.cmp, this)
  }
}
