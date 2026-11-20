// @ts-check
/* eslint-disable jsdoc/reject-any-type --
   BTree is a generic ordered container. The node internals and the comparator
   are `any`; the public BTree / BTreeSet shapes carry real types via @template. */

// A B+tree presenting the Map / Set interface, ordered by a supplied
// comparator. All entries live in leaves; leaves are chained left-to-right so
// iteration is in key order. A tree under M entries is a single leaf, so a
// small collection carries almost no tree overhead.
//
// This first cut is mutable: set() inserts or overwrites in place. Deletion
// and copy-on-write node sharing are deliberately not here yet.

const M = 32 // max keys per node

class Leaf {
  constructor() {
    /** @type {any[]} */
    this.keys = []
    /** @type {any[]} */
    this.vals = []
    /** @type {Leaf | null} */
    this.next = null
  }
}

class Branch {
  constructor() {
    /** @type {any[]} separators; keys.length === kids.length - 1 */
    this.keys = []
    /** @type {(Leaf | Branch)[]} */
    this.kids = []
  }
}

/**
 * First index i with cmp(xs[i], key) >= 0.
 * @param {any[]} xs
 * @param {any} key
 * @param {(a: any, b: any) => number} cmp
 */
function lowerBound(xs, key, cmp) {
  let lo = 0
  let hi = xs.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (cmp(xs[mid], key) < 0) lo = mid + 1
    else hi = mid
  }
  return lo
}

/**
 * First index i with cmp(xs[i], key) > 0.
 * @param {any[]} xs
 * @param {any} key
 * @param {(a: any, b: any) => number} cmp
 */
function upperBound(xs, key, cmp) {
  let lo = 0
  let hi = xs.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (cmp(xs[mid], key) <= 0) lo = mid + 1
    else hi = mid
  }
  return lo
}

/**
 * @template K
 * @template V
 */
export class BTree {
  #cmp
  /** @type {Leaf | Branch} */
  #root = new Leaf()
  #size = 0

  /**
   * @param {(a: K, b: K) => number} compare
   * @param {Iterable<[K, V]>} [entries]
   */
  constructor(compare, entries) {
    this.#cmp = compare
    if (entries) for (const [k, v] of entries) this.set(k, v)
  }

  get size() {
    return this.#size
  }

  /** The comparator this tree orders by. */
  get compare() {
    return this.#cmp
  }

  /**
   * @param {K} key
   * @returns {{ leaf: Leaf, path: [Branch, number][] }}
   */
  #descend(key) {
    let node = this.#root
    /** @type {[Branch, number][]} */
    const path = []
    while (node instanceof Branch) {
      const i = upperBound(node.keys, key, this.#cmp)
      path.push([node, i])
      node = node.kids[i]
    }
    return { leaf: node, path }
  }

  /**
   * @param {K} key
   * @returns {V | undefined}
   */
  get(key) {
    const { leaf } = this.#descend(key)
    const i = lowerBound(leaf.keys, key, this.#cmp)
    return i < leaf.keys.length && this.#cmp(leaf.keys[i], key) === 0
      ? leaf.vals[i]
      : undefined
  }

  /**
   * @param {K} key
   * @returns {boolean}
   */
  has(key) {
    const { leaf } = this.#descend(key)
    const i = lowerBound(leaf.keys, key, this.#cmp)
    return i < leaf.keys.length && this.#cmp(leaf.keys[i], key) === 0
  }

  /**
   * Insert, or overwrite the value at an equal key.
   * @param {K} key
   * @param {V} value
   * @returns {this}
   */
  set(key, value) {
    const { leaf, path } = this.#descend(key)
    const i = lowerBound(leaf.keys, key, this.#cmp)
    if (i < leaf.keys.length && this.#cmp(leaf.keys[i], key) === 0) {
      leaf.vals[i] = value
      return this
    }
    leaf.keys.splice(i, 0, key)
    leaf.vals.splice(i, 0, value)
    this.#size++
    if (leaf.keys.length > M) this.#splitLeaf(leaf, path)
    return this
  }

  /**
   * @param {Leaf} leaf
   * @param {[Branch, number][]} path
   */
  #splitLeaf(leaf, path) {
    const mid = leaf.keys.length >> 1
    const right = new Leaf()
    right.keys = leaf.keys.splice(mid)
    right.vals = leaf.vals.splice(mid)
    right.next = leaf.next
    leaf.next = right
    this.#insertUp(path, right.keys[0], right)
  }

  /**
   * File `right` (with separator `sep`) into its parent, splitting branches
   * that overflow. An empty path means the root split.
   * @param {[Branch, number][]} path
   * @param {K} sep
   * @param {Leaf | Branch} right
   */
  #insertUp(path, sep, right) {
    if (path.length === 0) {
      const root = new Branch()
      root.keys = [sep]
      root.kids = [this.#root, right]
      this.#root = root
      return
    }
    const [branch, i] = path.pop()
    branch.keys.splice(i, 0, sep)
    branch.kids.splice(i + 1, 0, right)
    if (branch.keys.length > M) {
      const mid = branch.keys.length >> 1
      const up = branch.keys[mid] // the middle key moves up, not copied
      const rb = new Branch()
      rb.keys = branch.keys.splice(mid + 1)
      rb.kids = branch.kids.splice(mid + 1)
      branch.keys.splice(mid) // drop the promoted key
      this.#insertUp(path, up, rb)
    }
  }

  /** @returns {Leaf} */
  #firstLeaf() {
    let n = this.#root
    while (n instanceof Branch) n = n.kids[0]
    return n
  }

  /**
   * @yields {[K, V]}
   * @returns {Generator<[K, V], void>}
   */
  *entries() {
    for (let l = this.#firstLeaf(); l; l = l.next) {
      for (let i = 0; i < l.keys.length; i++) yield [l.keys[i], l.vals[i]]
    }
  }

  /**
   * @yields {K}
   * @returns {Generator<K, void>}
   */
  *keys() {
    for (const e of this.entries()) yield e[0]
  }

  /**
   * @yields {V}
   * @returns {Generator<V, void>}
   */
  *values() {
    for (const e of this.entries()) yield e[1]
  }

  [Symbol.iterator]() {
    return this.entries()
  }

  /**
   * @param {(value: V, key: K, tree: this) => void} fn
   * @param {unknown} [self]
   */
  forEach(fn, self) {
    for (const [k, v] of this.entries()) fn.call(self, v, k, this)
  }

  /**
   * An independent copy. Keys and values are shared; nodes are not.
   * @returns {BTree<K, V>}
   */
  clone() {
    return new BTree(this.#cmp, this.entries())
  }
}

const PRESENT = Symbol('present')

/**
 * @template T
 */
export class BTreeSet {
  /** @type {BTree<T, symbol>} */
  #tree

  /**
   * @param {(a: T, b: T) => number} compare
   * @param {Iterable<T>} [values]
   */
  constructor(compare, values) {
    this.#tree = new BTree(compare)
    if (values) for (const v of values) this.#tree.set(v, PRESENT)
  }

  get size() {
    return this.#tree.size
  }

  get compare() {
    return this.#tree.compare
  }

  /**
   * @param {T} v
   * @returns {this}
   */
  add(v) {
    this.#tree.set(v, PRESENT)
    return this
  }

  /**
   * @param {T} v
   * @returns {boolean}
   */
  has(v) {
    return this.#tree.has(v)
  }

  /**
   * @yields {T}
   * @returns {Generator<T, void>}
   */
  *values() {
    yield* this.#tree.keys()
  }

  keys() {
    return this.values()
  }

  /**
   * @yields {[T, T]}
   * @returns {Generator<[T, T], void>}
   */
  *entries() {
    for (const v of this.values()) yield [v, v]
  }

  [Symbol.iterator]() {
    return this.values()
  }

  /**
   * @param {(value: T, value2: T, set: this) => void} fn
   * @param {unknown} [self]
   */
  forEach(fn, self) {
    for (const v of this.values()) fn.call(self, v, v, this)
  }

  /** @returns {BTreeSet<T>} */
  clone() {
    return new BTreeSet(this.#tree.compare, this.values())
  }
}
