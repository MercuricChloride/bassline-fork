// @ts-check

// Procedures over admitted values.

/** @import {Value, Values} from './forms.js' */
import { assertValue } from './forms.js'
import { eq, list, record, set, dict } from './codec.js'

/**
 * Yield a value and every constituent, depth-first, in document order.
 * @param {Value} v
 * @yields {Value}
 * @returns {Generator<Value, void>}
 */
export function* walk(v) {
  yield v
  switch (v.kind) {
    case 'list':
    case 'record':
    case 'set':
      for (const item of v.value) yield* walk(item)
      break
    case 'dict':
      for (const [key, value] of v.value) {
        yield* walk(key)
        yield* walk(value)
      }
      break
  }
}

/**
 * @param {Value} v
 */
export function hasActionable(v) {
  for (const el of walk(v)) {
    if (el.actionable) return true
  }
  return false
}

/**
 * True when no value contains itself
 * @param {Value} v
 */
export function cycleFree(v) {
  const path = new Set()
  /**
   * @param {Value} node
   * @returns {boolean}
   */
  function go(node) {
    if (path.has(node)) return false
    path.add(node)
    let ok = true
    switch (node.kind) {
      case 'list':
      case 'record':
      case 'set':
        ok = node.value.every(go)
        break
      case 'dict':
        ok = node.value.every(([key, value]) => go(key) && go(value))
        break
    }
    path.delete(node)
    return ok
  }
  return go(v)
}

/** @param {Value} v */
export const isData = v => (assertValue(v), !hasActionable(v))

/** @param {Value} v */
export const isActionable = v => (assertValue(v), v.actionable)

/**
 * The same value with the mark set as given (a shallow copy when it differs).
 * @param {Value} v
 * @param {boolean} actionable
 * @returns {Value}
 */
export function withMark(v, actionable = true) {
  assertValue(v)
  if (v.actionable === actionable) return v
  return Object.freeze({ ...v, actionable })
}

/**
 * Rebuild a frame by applying fn over its constituents — dict constituents
 * are [key, value] pairs — preserving the mark. Atoms come back unchanged.
 * @param {Value} v
 * @param {(x: Value | [Value, Value]) => Value | [Value, Value]} fn
 * @returns {Value}
 */
export function map(v, fn) {
  const each = /** @type {(x: Value) => Value} */ (fn)
  const eachEntry = /** @type {(e: [Value, Value]) => [Value, Value]} */ (fn)
  switch (v.kind) {
    case 'list':
      return list(v.value.map(each), v.actionable)
    case 'record':
      return record(v.value.map(each), v.actionable)
    case 'set':
      return set(v.value.map(each), v.actionable)
    case 'dict':
      return dict(v.value.map(eachEntry), v.actionable)
    default:
      return v
  }
}

/**
 * The value under `key`, or undefined when the dictionary doesn't speak of it.
 * @param {Values['dict']} d
 * @param {Value} key
 */
export function dictGet(d, key) {
  for (const [k, value] of d.value) {
    if (eq(k, key)) return value
  }
  return undefined
}

/**
 * Membership by value.
 * @param {Values['set']} s
 * @param {Value} v
 */
export function setHas(s, v) {
  return s.value.some(member => eq(member, v))
}
