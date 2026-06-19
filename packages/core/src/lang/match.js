//@ts-check
/** @import {Value, Values} from "../data.js" */
/** @typedef {(v: Value) => boolean} Predicate */

/**
 * @template {Value} T
 * @typedef {(x: Value) => x is T} Guard
 */

export const kind = {
  /** @type {Guard<Values['nil']>} */
  nil: aNode => aNode.kind === 'nil',
  /** @type {Guard<Values['bool']>} */
  bool: aNode => aNode.kind === 'bool',
  /** @type {Guard<Values['int']>} */
  int: aNode => aNode.kind === 'int',
  /** @type {Guard<Values['float']>} */
  float: aNode => aNode.kind === 'float',
  /** @type {Guard<Values['string']>} */
  string: aNode => aNode.kind === 'string',
  /** @type {Guard<Values['symbol']>} */
  symbol: aNode => aNode.kind === 'symbol',
  /** @type {Guard<Values['bytes']>} */
  bytes: aNode => aNode.kind === 'bytes',
  /** @type {Guard<Values['list']>} */
  list: aNode => aNode.kind === 'list',
  /** @type {Guard<Values['dict']>} */
  dict: aNode => aNode.kind === 'dict',
  /** @type {Guard<Values['record']>} */
  record: aNode => aNode.kind === 'record',
  /** @type {Guard<Values['set']>} */
  set: aNode => aNode.kind === 'set',
}

/** @type {(...preds: Predicate[]) => Predicate} */
export const and =
  (...preds) =>
  aNode =>
    preds.every(p => p(aNode))

/** @type {(...preds: Predicate[]) => Predicate} */
export const or =
  (...preds) =>
  aNode =>
    preds.some(p => p(aNode))

/** @type {(p: Predicate) => Predicate} */
export const not = p => aNode => !p(aNode)

export const frame = or(kind.record, kind.list, kind.dict, kind.set)

/** @type {Predicate} */
export const actionable = aNode => aNode.actionable

export const passive = not(actionable)

export const any = () => true

/** @type {(p: Predicate) => Predicate} */
export const head = p => aNode => kind.record(aNode) && p(aNode.head)

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
