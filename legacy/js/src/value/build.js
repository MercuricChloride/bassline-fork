// @ts-check

// The one construction surface. The text reader, foreign-format doors, and
// host-type lowering all build through here, so a value made any way is the
// same kind of thing. fromForeign is the open hook (Nim's `toValue`).

import { BTree, BTreeSet } from '../btree.js'
import {
  BValue,
  BNil,
  BInt,
  BText,
  BSym,
  BBytes,
  BList,
  BRecord,
  BDict,
  BSet,
  isValue,
  byValue,
} from './value.js'

/** @import { Value } from './value.js' */

// A value is immutable by convention, like the Nim side: it is not mutated
// after it leaves its builder, and ops build new values. The frame
// constructors take a private copy of the members array so a later write to
// the caller's array can't reach in.

// ================ constructors ================

/**
 * @param {boolean} [mark]
 */
export const nil = (mark = false) => new BNil(mark)

/**
 * @param {number | bigint} n
 * @param {boolean} [mark]
 */
export const int = (n, mark = false) => new BInt(n, mark)

/**
 * @param {string} s
 * @param {boolean} [mark]
 */
export const text = (s, mark = false) => new BText(s, mark)

/**
 * @param {string} s
 * @param {boolean} [mark]
 */
export const symbol = (s, mark = false) => new BSym(s, mark)

/**
 * @param {Uint8Array} b
 * @param {boolean} [mark]
 */
export const bytes = (b, mark = false) => new BBytes(b, mark)

/**
 * @param {Value[]} items
 * @param {boolean} [mark]
 */
export function list(items, mark = false) {
  return new BList(items4(items, 'list'), mark)
}

/**
 * @param {Value[]} items head first, at least one
 * @param {boolean} [mark]
 */
export function record(items, mark = false) {
  const it = items4(items, 'record')
  if (it.length === 0) throw new TypeError('a record needs a head')
  return new BRecord(it, mark)
}

/**
 * @param {Value[]} members duplicates are dropped canonically
 * @param {boolean} [mark]
 */
export function set(members, mark = false) {
  if (!Array.isArray(members) || !members.every(isValue)) {
    throw new TypeError('set expects an array of Bassline values')
  }
  return new BSet(new BTreeSet(byValue, members), mark)
}

/**
 * @param {Array<[Value, Value]>} entries a repeated key keeps the last
 * @param {boolean} [mark]
 */
export function dict(entries, mark = false) {
  if (
    !Array.isArray(entries) ||
    !entries.every(e => Array.isArray(e) && isValue(e[0]) && isValue(e[1]))
  ) {
    throw new TypeError('dict expects an array of [key, value] entries')
  }
  return new BDict(new BTree(byValue, entries), mark)
}

/**
 * Validate the members and take a private copy the value will own.
 * @param {unknown} items
 * @param {string} what
 * @returns {readonly Value[]}
 */
function items4(items, what) {
  if (!Array.isArray(items) || !items.every(isValue)) {
    throw new TypeError(what + ' expects an array of Bassline values')
  }
  return items.slice()
}

// ================ the foreign hook ================

/** A host object may define this method to lower itself to a value. */
export const TO_VALUE = Symbol.for('bassline.toValue')

/** @type {Array<(x: unknown) => Value | undefined>} */
const lowerings = []

/**
 * Register a lowering for a host primitive the method form can't cover.
 * @param {(x: unknown) => Value | undefined} fn
 */
export function registerLowering(fn) {
  lowerings.push(fn)
}

/**
 * Bring a foreign thing across the value boundary: a value passes through, an
 * object with a `[TO_VALUE]()` method lowers itself, otherwise a registered
 * lowering handles it. Refuses what nothing recognises.
 * @param {unknown} x
 * @returns {Value}
 */
export function fromForeign(x) {
  if (x instanceof BValue) return /** @type {Value} */ (x)
  const method =
    x == null ? undefined : /** @type {Record<symbol, unknown>} */ (x)[TO_VALUE]
  if (typeof method === 'function') {
    const v = method.call(x)
    if (v instanceof BValue) return /** @type {Value} */ (v)
    throw new TypeError('[TO_VALUE] did not return a Bassline value')
  }
  for (const fn of lowerings) {
    const v = fn(x)
    if (v !== undefined) return v
  }
  throw new TypeError('no value lowering for ' + typeof x)
}
