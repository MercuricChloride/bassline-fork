// @ts-check

// The in-memory reading of a value: a small class tree whose order reproduces
// CE order structurally — no encoding, ever. This is the surface programs
// manipulate. The byte-backed reading (identity = CE span) is ValueView, over
// in codec/decode.js.
//
//   BValue
//   ├─ BAtom   ─ BNil BInt BText BSym BBytes
//   └─ BFrame  ─ BList BRecord BDict BSet
//
// mark is one orthogonal bit, a field on every value, immutable per handle.
// compare / equals live on the classes: BValue does the shared kind+mark
// preamble, each leaf implements _compareSame for two values of one kind.

import { KIND } from '../codec/header.js'
import { compareShortlex } from '../codec/payload.js'

/** @import { Kind } from '../codec/header.js' */
/** @import { BTree, BTreeSet } from '../btree.js' */
/** @import { Visitor } from './visitor.js' */

/**
 * The nine value kinds as a discriminated union — the type consumers annotate
 * with. `BValue` is the abstract class; `Value` is the union that narrows on
 * `.kind`.
 * @typedef {BNil | BInt | BText | BSym | BBytes | BList | BRecord | BDict | BSet} Value
 * @typedef {BNil | BInt | BText | BSym | BBytes} Atom
 * @typedef {BList | BRecord | BDict | BSet} Frame
 */

const ENC = new TextEncoder()
const EMPTY = new Uint8Array(0)
const MIN_SAFE = BigInt(Number.MIN_SAFE_INTEGER)
const MAX_SAFE = BigInt(Number.MAX_SAFE_INTEGER)

/**
 * Order two same-kind, same-mark frames member by member, then longer first.
 * Every frame kind reduces to this: a list or record over its items, a set
 * over its members, a dict over its flat key, value, key, value sequence (so a
 * member-wise walk is pairwise key-then-value and the size tiebreak falls out).
 * @param {readonly Value[]} a
 * @param {readonly Value[]} b
 */
function compareItems(a, b) {
  const n = Math.min(a.length, b.length)
  for (let i = 0; i < n; i++) {
    const c = a[i].compare(b[i])
    if (c !== 0) return c
  }
  // a shorter frame sorts after a longer one it prefixes: END (0xA0) outranks
  // any header the longer frame continues with
  return b.length - a.length
}

export class BValue {
  #mark

  /** @param {boolean} [mark] */
  constructor(mark = false) {
    this.#mark = mark === true
  }

  get mark() {
    return this.#mark
  }

  /* eslint-disable jsdoc/require-returns-check -- abstract stub; every leaf overrides it */
  /**
   * The kind name: nil, number, text, symbol, bytes, list, record, dict, set.
   * @returns {Kind}
   */
  get kind() {
    throw new Error('BValue.kind is abstract')
  }
  /* eslint-enable jsdoc/require-returns-check */

  /** @returns {this is Atom} */
  isAtom() {
    return this instanceof BAtom
  }

  /** @returns {this is Frame} */
  isFrame() {
    return this instanceof BFrame
  }

  /**
   * CE order, reproduced without encoding: kind, then mark, then the per-kind
   * body. Total over the value space.
   * @param {Value} other
   * @returns {number}
   */
  compare(other) {
    if (Object.is(this, other)) return 0
    const k = KIND[this.kind] - KIND[other.kind]
    if (k !== 0) return k
    const m = (this.#mark ? 1 : 0) - (other.mark ? 1 : 0)
    if (m !== 0) return m
    return this._compareSame(other)
  }

  /**
   * Order two values of the same kind and mark. Overridden per leaf.
   * @param {Value} _other
   * @returns {number}
   */
  _compareSame(_other) {
    return 0
  }

  /** @param {Value} other */
  equals(other) {
    return this.compare(other) === 0
  }

  /**
   * `this` typed as the discriminated union. `BValue` is abstract, so every
   * instance is in fact one of the nine leaves; this just tells the checker.
   * @returns {Value}
   */
  #asValue() {
    return /** @type {Value} */ (/** @type {unknown} */ (this))
  }

  /**
   * The same value with the mark set as given — a fresh handle over the same
   * body (frames share their members). A no-op when the mark already matches.
   * Prefer the free {@link withMark}; this method spares callers a re-check.
   * @param {boolean} [on]
   * @returns {Value}
   */
  withMark(on = true) {
    return withMark(this.#asValue(), on)
  }

  /**
   * Rebuild with `mark`, sharing the body. Every leaf overrides this.
   * @param {boolean} _mark
   * @returns {Value}
   */
  _withMark(_mark) {
    return this.#asValue()
  }

  /**
   * Dispatch to the matching visitor hook. Each leaf overrides this with its
   * specific hook; the base falls through to the general one.
   * @param {Visitor} visitor
   * @returns {unknown}
   */
  accept(visitor) {
    return visitor.visitValue(this.#asValue())
  }
}

export class BAtom extends BValue {
  /** @type {Uint8Array | undefined} */
  #payload

  /** The payload bytes this atom contributes to CE. Lazy, memoized. */
  payloadBytes() {
    if (this.#payload === undefined) this.#payload = this._payload()
    return this.#payload
  }

  /** @returns {Uint8Array} */
  _payload() {
    return EMPTY
  }
}

export class BNil extends BAtom {
  /** @returns {'nil'} */
  get kind() {
    return 'nil'
  }
  /** @param {boolean} mark */
  _withMark(mark) {
    return new BNil(mark)
  }
  /** @param {Visitor} v */
  accept(v) {
    return v.visitNil(this)
  }
}

/**
 * The length of x's canonical decimal spelling, sign included.
 * @param {number | bigint} x
 */
function spellLen(x) {
  const mag = x < 0 ? -x : x
  return (x < 0 ? 1 : 0) + mag.toString().length
}

export class BInt extends BAtom {
  /** @type {number | bigint} */
  #n

  /**
   * @param {number | bigint} n an integer; a number is kept where exact and
   *   promoted to bigint otherwise
   * @param {boolean} [mark]
   */
  constructor(n, mark) {
    super(mark)
    if (typeof n === 'number') {
      if (!Number.isInteger(n)) throw new TypeError('int expects an integer')
      this.#n = Number.isSafeInteger(n) ? n + 0 : BigInt(n)
    } else if (typeof n === 'bigint') {
      // keep the smallest representation: a number where it fits exactly
      this.#n = n >= MIN_SAFE && n <= MAX_SAFE ? Number(n) : n
    } else {
      throw new TypeError('int expects a number or bigint')
    }
  }

  /** The native representation — a number where exact, else a bigint. */
  get value() {
    return this.#n
  }

  toBigInt() {
    return typeof this.#n === 'bigint' ? this.#n : BigInt(this.#n)
  }

  /** @returns {'number'} */
  get kind() {
    return 'number'
  }
  /** @param {boolean} mark */
  _withMark(mark) {
    return new BInt(this.#n, mark)
  }
  /** @param {Visitor} v */
  accept(v) {
    return v.visitInt(this)
  }
  _payload() {
    return ENC.encode(String(this.#n))
  }

  /** @param {BInt} o */
  _compareSame(o) {
    const x = this.#n
    const y = o.#n
    const lx = spellLen(x)
    const ly = spellLen(y)
    if (lx !== ly) return lx - ly
    const nx = x < 0
    const ny = y < 0
    if (nx !== ny) return nx ? -1 : 1
    // same spelling length, same sign: the digits compare bytewise, which is
    // magnitude order (the leading '-' is a shared prefix)
    const mx = nx ? -x : x
    const my = ny ? -y : y
    return mx < my ? -1 : mx > my ? 1 : 0
  }
}

class BStringLike extends BAtom {
  #s

  /**
   * @param {string} s
   * @param {boolean | undefined} mark
   * @param {string} what
   */
  constructor(s, mark, what) {
    super(mark)
    if (typeof s !== 'string') throw new TypeError(what + ' expects a string')
    if (!s.isWellFormed()) throw new Error(what + ' is not well-formed')
    this.#s = s
  }

  get value() {
    return this.#s
  }
  _payload() {
    return ENC.encode(this.#s)
  }
  /** @param {BText | BSym} o */
  _compareSame(o) {
    return compareShortlex(this.payloadBytes(), o.payloadBytes())
  }
}

export class BText extends BStringLike {
  /**
   * @param {string} s
   * @param {boolean} [mark]
   */
  constructor(s, mark) {
    super(s, mark, 'text')
  }
  /** @returns {'text'} */
  get kind() {
    return 'text'
  }
  /** @param {boolean} mark */
  _withMark(mark) {
    return new BText(this.value, mark)
  }
  /** @param {Visitor} v */
  accept(v) {
    return v.visitText(this)
  }
}

export class BSym extends BStringLike {
  /**
   * @param {string} s
   * @param {boolean} [mark]
   */
  constructor(s, mark) {
    super(s, mark, 'symbol')
  }
  /** @returns {'symbol'} */
  get kind() {
    return 'symbol'
  }
  /** @param {boolean} mark */
  _withMark(mark) {
    return new BSym(this.value, mark)
  }
  /** @param {Visitor} v */
  accept(v) {
    return v.visitSym(this)
  }
}

export class BBytes extends BAtom {
  #b

  /**
   * @param {Uint8Array} b
   * @param {boolean} [mark]
   */
  constructor(b, mark) {
    super(mark)
    if (!(b instanceof Uint8Array)) {
      throw new TypeError('bytes expects a Uint8Array')
    }
    this.#b = b.slice() // own it; a later write to the caller's array can't reach here
  }

  /** A copy of the payload bytes. */
  get value() {
    return this.#b.slice()
  }
  /** @returns {'bytes'} */
  get kind() {
    return 'bytes'
  }
  /** @param {boolean} mark */
  _withMark(mark) {
    return new BBytes(this.#b, mark)
  }
  /** @param {Visitor} v */
  accept(v) {
    return v.visitBytes(this)
  }
  _payload() {
    return this.#b
  }
  /** @param {BBytes} o */
  _compareSame(o) {
    return compareShortlex(this.#b, o.#b)
  }
}

export class BFrame extends BValue {
  /** @returns {Iterable<Value>} the constituents, in document order */
  members() {
    return []
  }
}

export class BList extends BFrame {
  /** @type {readonly Value[]} */
  #items

  /**
   * @param {readonly Value[]} items owned by this value; do not mutate
   * @param {boolean} [mark]
   */
  constructor(items, mark) {
    super(mark)
    this.#items = items
  }

  get items() {
    return this.#items
  }
  get size() {
    return this.#items.length
  }
  /** @param {number} i */
  at(i) {
    return this.#items[i]
  }
  members() {
    return this.#items
  }
  [Symbol.iterator]() {
    return this.#items[Symbol.iterator]()
  }
  /** @returns {'list'} */
  get kind() {
    return 'list'
  }
  /** @param {boolean} mark */
  _withMark(mark) {
    return new BList(this.#items, mark)
  }
  /** @param {Visitor} v */
  accept(v) {
    return v.visitList(this)
  }
  /** @param {BList} o */
  _compareSame(o) {
    return compareItems(this.#items, o.#items)
  }
}

export class BRecord extends BFrame {
  /** @type {readonly Value[]} length >= 1 */
  #items

  /**
   * @param {readonly Value[]} items non-empty, head first; owned, do not mutate
   * @param {boolean} [mark]
   */
  constructor(items, mark) {
    super(mark)
    this.#items = items
  }

  get items() {
    return this.#items
  }
  get head() {
    return this.#items[0]
  }
  get fields() {
    return this.#items.slice(1)
  }
  get size() {
    return this.#items.length
  }
  members() {
    return this.#items
  }
  [Symbol.iterator]() {
    return this.#items[Symbol.iterator]()
  }
  /** @returns {'record'} */
  get kind() {
    return 'record'
  }
  /** @param {boolean} mark */
  _withMark(mark) {
    return new BRecord(this.#items, mark)
  }
  /** @param {Visitor} v */
  accept(v) {
    return v.visitRecord(this)
  }
  /** @param {BRecord} o */
  _compareSame(o) {
    return compareItems(this.#items, o.#items)
  }
}

export class BDict extends BFrame {
  /** @type {BTree<Value, Value>} */
  #tree

  /**
   * @param {BTree<Value, Value>} tree ordered by Value.compare
   * @param {boolean} [mark]
   */
  constructor(tree, mark) {
    super(mark)
    this.#tree = tree
  }

  /** @returns {'dict'} */
  get kind() {
    return 'dict'
  }
  get size() {
    return this.#tree.size
  }
  /** @param {Value} key */
  get(key) {
    return this.#tree.get(key)
  }
  /** @param {Value} key */
  has(key) {
    return this.#tree.has(key)
  }
  entries() {
    return this.#tree.entries()
  }
  keys() {
    return this.#tree.keys()
  }
  values() {
    return this.#tree.values()
  }
  [Symbol.iterator]() {
    return this.#tree.entries()
  }
  /**
   * The flat constituent sequence: key, value, key, value, ...
   * @yields {Value}
   * @returns {Generator<Value, void>}
   */
  *members() {
    for (const [k, v] of this.#tree.entries()) {
      yield k
      yield v
    }
  }
  /** The backing tree — for ops that build a derived dict. */
  get tree() {
    return this.#tree
  }
  /** @param {boolean} mark */
  _withMark(mark) {
    return new BDict(this.#tree, mark)
  }
  /** @param {Visitor} v */
  accept(v) {
    return v.visitDict(this)
  }
  /** @param {BDict} o */
  _compareSame(o) {
    return compareItems([...this.members()], [...o.members()])
  }
}

export class BSet extends BFrame {
  /** @type {BTreeSet<Value>} */
  #set

  /**
   * @param {BTreeSet<Value>} set ordered by Value.compare
   * @param {boolean} [mark]
   */
  constructor(set, mark) {
    super(mark)
    this.#set = set
  }

  /** @returns {'set'} */
  get kind() {
    return 'set'
  }
  get size() {
    return this.#set.size
  }
  /** @param {Value} v */
  has(v) {
    return this.#set.has(v)
  }
  values() {
    return this.#set.values()
  }
  keys() {
    return this.#set.values()
  }
  [Symbol.iterator]() {
    return this.#set.values()
  }
  members() {
    return this.#set.values()
  }
  /** The backing set — for ops that build a derived set. */
  get treeSet() {
    return this.#set
  }
  /** @param {boolean} mark */
  _withMark(mark) {
    return new BSet(this.#set, mark)
  }
  /** @param {Visitor} v */
  accept(v) {
    return v.visitSet(this)
  }
  /** @param {BSet} o */
  _compareSame(o) {
    return compareItems([...this.members()], [...o.members()])
  }
}

// ================ predicates ================

/**
 * @param {unknown} x
 * @returns {x is Value}
 */
export const isValue = x => x instanceof BValue

/**
 * @param {unknown} x
 * @returns {x is Atom}
 */
export const isAtom = x => x instanceof BAtom

/**
 * @param {unknown} x
 * @returns {x is Frame}
 */
export const isFrame = x => x instanceof BFrame

/**
 * @param {unknown} x
 * @param {string} [msg]
 * @returns {asserts x is Value}
 */
export function assertValue(x, msg = 'expected a Bassline value') {
  if (!isValue(x)) throw new TypeError(msg)
}

// ================ comparison, as free functions ================

/**
 * CE order between two values, checking both are values first. The `compare`
 * method is the unchecked fast path for code that already knows its types.
 * @param {Value} a
 * @param {Value} b
 * @returns {number}
 */
export function cmp(a, b) {
  assertValue(a)
  assertValue(b)
  return a.compare(b)
}

/**
 * Canonical equality between two values, checking both are values first.
 * @param {Value} a
 * @param {Value} b
 * @returns {boolean}
 */
export function eq(a, b) {
  assertValue(a)
  assertValue(b)
  return a.equals(b)
}

/**
 * `Value.compare` as a plain comparator — the order a {@link BTree} or
 * {@link BTreeSet} takes when it backs a dict or set. Unchecked, unlike
 * {@link cmp}: callers here already hold values.
 * @param {Value} a
 * @param {Value} b
 * @returns {number}
 */
export const byValue = (a, b) => a.compare(b)

/**
 * The same value with the mark set as given — a fresh handle over the shared
 * body (frames share their members). A no-op when the mark already matches.
 * @param {Value} v
 * @param {boolean} [on]
 * @returns {Value}
 */
export function withMark(v, on = true) {
  const want = on === true
  return v.mark === want ? v : v._withMark(want)
}
