// @ts-check

/** @import {Value, Values, Atom} from './forms.js' */
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
 *
 * @param {Value} v
 * @yields {Atom}
 * @returns {Generator<Atom, void>}
 */
export function* atoms(v) {
  for (const val of walk(v)) {
    switch (val.kind) {
      case 'nil':
      case 'int':
      case 'string':
      case 'symbol':
      case 'bytes':
        yield val
    }
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
 * @overload
 * @param {Values['dict']} v
 * @param {(x: [Value, Value]) => [Value, Value]} fn
 * @returns {Values['dict']}
 */

/**
 * @overload
 * @param {Values['list']} v
 * @param {(x: Value) => Value} fn
 * @returns {Values['list']}
 */

/**
 * @overload
 * @param {Values['set']} v
 * @param {(x: Value) => Value} fn
 * @returns {Values['set']}
 */

/**
 * @overload
 * @param {Values['record']} v
 * @param {(x: Value) => Value} fn
 * @returns {Values['record']}
 */

/**
 * Rebuild a frame by applying fn over its constituents — dict constituents
 * are [key, value] pairs — preserving the mark. Atoms come back unchanged.
 * @param {Value} v
 * @param {((x: Value) => Value) | ((x: [Value, Value]) => [Value, Value])} fn
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
 * The value under `key`, or undefined when the dict / set doesn't speak of it.
 * @param {Values[('dict' | 'set')]} v
 * @param {Value} key
 * @throws {TypeError} when v isn't a dict / set
 */
export function at(v, key) {
  switch (v.kind) {
    case 'dict':
      for (const [k, value] of v.value) {
        if (eq(k, key)) return value
      }
      return undefined
    case 'set':
      for (const value of v.value) {
        if (eq(value, key)) return value
      }
      return undefined
    default:
      throw new TypeError('at requires a dictionary or set!')
  }
}

/**
 * @overload
 * @param {Values['dict']} v
 * @param {Value} key
 * @param {Value} Value
 * @returns {Values['dict']}
 */

/**
 * @overload
 * @param {Values['set']} v
 * @param {Value} value
 * @returns {Values['set']}
 */

/**
 * Associate value  `key`, or undefined when the dict / set doesn't speak of it.
 * @param {Values[('dict' | 'set')]} v
 * @param {[Value] | [Value, Value]} args
 * @throws {TypeError} when v isn't a dict / set
 */
export function assoc(v, ...args) {
  switch (v.kind) {
    case 'dict': {
      const [key, val] = args
      return dict([...v.value, [key, val]])
    }
    case 'set': {
      const [val] = args
      return set([...v.value, val])
    }
    default:
      throw new TypeError('assoc requires a dictionary or set!')
  }
}
