// Tree rewriting over bassline values.
//
// Two structural primitives — children() and rebuild() — turn the data model
// into something you can walk generically: every value is its ordered children
// plus a way to put new children back. rewrite() drives a rule over the tree to
// a fixpoint, and a few combinators (rules/onHead/onSymbol) build rules.
//
// A *rule* is `(node) => Value`: return a new node to keep rewriting, or return
// the node unchanged to decline. Rules are plain functions, so they compose and
// stay value-friendly (the door to authoring rules as bassline values later).
/** @import { BasslineValue } from '../data.js' */
import {
  isValue,
  eq,
  BasslineDict,
  BasslineRecord,
  BasslineSymbol,
} from '../data.js'

/**
 * Rewrite a value tree with a rule, bottom-up. Children are rewritten first,
 * the node is rebuilt, then the rule is applied; if the rule changed the node
 * (by canonical-encoding equality) the result is rewritten again, to a fixpoint.
 * @param {import('../data.js').BasslineValue} v
 * @param {(node) => import('../data.js').BasslineValue} rule
 * @param {{ fixpoint?: boolean, maxSteps?: number }} [opts]
 */
export function rewrite(v, rule, opts = {}) {
  const { fixpoint = true, maxSteps = 100000 } = opts
  let steps = 0
  const go = node => {
    let rebuilt
    if (node instanceof BasslineDict) {
      rebuilt = node.map(([k, v]) => [go(k), go(v)])
    } else if (node.isFrame) {
      rebuilt = node.map(go)
    } else {
      rebuilt = node
    }
    const out = rule(rebuilt)
    if (!isValue(out)) {
      throw new TypeError('a rewrite rule must return a Bassline value')
    }

    if (fixpoint && !eq(out, rebuilt)) {
      if (++steps > maxSteps)
        throw new Error('rewrite did not reach a fixpoint within maxSteps')
      return go(out)
    }
    return out
  }
  return go(v)
}

// ================ rule combinators ================

/**
 * Try each rule in order; the first that changes the node wins.
 * @param {...((node: BasslineValue) => BasslineValue)[]} rs
 * @returns {(node: BasslineValue) => BasslineValue}
 */
export function rules(...rs) {
  return node => {
    for (const r of rs) {
      const out = r(node)
      if (!eq(out, node)) return out
    }
    return node
  }
}

/**
 * Match a record whose head is the symbol `name` (ignores the actionable bit).
 * @param name
 * @param fn
 */
export function onHead(name, fn) {
  return node => {
    if (
      node instanceof BasslineRecord &&
      node.head instanceof BasslineSymbol &&
      node.head.value === name
    ) {
      return fn(node)
    }
    return node
  }
}

/**
 * Match a symbol whose spelling satisfies `pred`.
 * @param pred
 * @param fn
 */
export function onSymbol(pred, fn) {
  return node => {
    if (node instanceof BasslineSymbol && pred(node.value)) {
      return fn(node)
    }
    return node
  }
}
