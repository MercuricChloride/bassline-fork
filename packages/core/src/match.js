//@ts-check
/** @import {BasslineRecord, Value, ValueKind} from "./data.js" */
/**
 * @template T
 * @typedef {(x: unknown) => x is T} Pred
 */

/**
 * @template {Value} [T=Value]
 * @typedef {(x: Value) => x is T} Predicate
 */

/**
 * @template T
 * @typedef {T extends (x: any, ...args: any[]) => x is infer K ? K : never} GuardOut
 */

/**
 * @template T
 * @typedef {T extends readonly [infer H, ...infer R] ? GuardOut<H> & AndOut<R> : unknown} AndOut
 */

/**
 * @template {Value} [T=Value]
 * @param {Predicate<T>} f
 */
function predicate(f) {
  /** @type {Predicate<T>} */
  return aValue => f(aValue)
}

export const kind = /** @constant */ {
  nil: predicate(aNode => aNode.kind === 'nil'),
  bool: predicate(aNode => aNode.kind === 'bool'),
  int: predicate(aNode => aNode.kind === 'int'),
  float: predicate(aNode => aNode.kind === 'float'),
  string: predicate(aNode => aNode.kind === 'string'),
  symbol: predicate(aNode => aNode.kind === 'symbol'),
  bytes: predicate(aNode => aNode.kind === 'bytes'),
  list: predicate(aNode => aNode.kind === 'list'),
  dict: predicate(aNode => aNode.kind === 'dict'),
  record: predicate(aNode => aNode.kind === 'record'),
  set: predicate(aNode => aNode.kind === 'set'),
}

/**
 * @template {Predicate[]} const T
 * @param {T} preds
 */
export const and =
  (...preds) =>
  /** @type {Predicate<AndOut<T>>} */
  aNode =>
    preds.every(p => p(aNode))

/**
 * @template {Predicate[]} const T
 * @param {T} preds
 */
export const or =
  (...preds) =>
  /** @type {Predicate<GuardOut<T[keyof T]>>} */
  aNode =>
    preds.some(p => p(aNode))

/** @type {(p: Predicate) => Predicate} */
export const not = p => aNode => !p(aNode)

export const frame = or(kind.record, kind.list, kind.dict, kind.set)

/** @type {Predicate} */
export const actionable = aNode => aNode.actionable

export const passive = not(actionable)

export const any = () => true

/**
 * @template {string} const T
 * @template {ValueKind} K
 * @param {T} name
 * @param {K} kind
 */
export function spelled(name, kind = null) {
  /** @type {Predicate<Value & {readonly value: T, readonly kind: K}>} */
  return aNode => {
    if (aNode.value !== name) return false
    if (kind && aNode.kind !== kind) return false
    return true
  }
}

/**
 * Creates a predicate that matches a record with a matching head
 * @template {Value} T
 * @param {Predicate<T>} p
 */
export function head(p) {
  /** @type {Predicate<BasslineRecord & {readonly head: T}>} */
  return aNode => kind.record(aNode) && p(aNode.head)
}

/** @type {(p: Predicate, f: (aNode: Value) => Value) => (aNode: Value) => Value} */
export const rule = (p, f) => aNode => (p(aNode) ? f(aNode) : aNode)

/**
 * @param {...[Predicate, (aNode: Value) => Value]} cases
 * @returns {(aNode: Value) => Value}
 */
export function match(...cases) {
  return aNode => {
    for (const [p, f] of cases) {
      if (p(aNode)) return f(aNode)
    }
    return aNode
  }
}
