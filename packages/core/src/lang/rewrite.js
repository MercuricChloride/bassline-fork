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
/** @import { Value } from '../data.js' */
import { assertValue } from '../data.js'
import { kind, match, frame, any, and, head, rule, spelled } from '../match.js'

/**
 * Rewrite a value tree with a rule, bottom-up. Children are rewritten first,
 * the node is rebuilt, then the rule is applied; if the rule changed the node
 * (by canonical-encoding equality) the result is rewritten again, to a fixpoint.
 * @param {Value} v
 * @param {(node: Value) => Value} rule
 * @param {{ fixpoint?: boolean, maxSteps?: number }} [opts]
 */
export function rewrite(v, rule, opts = {}) {
  const { fixpoint = true, maxSteps = 100000 } = opts
  let steps = 0
  const rebuild = match(
    [n => kind.dict(n), node => node.map(([k, v]) => [go(k), go(v)])],
    [frame, node => node.map(go)],
    [any, node => node]
  )
  /** @param {Value} node */
  function go(node) {
    const rebuilt = rebuild(node)
    const out = rule(rebuilt)
    assertValue(out, 'a rewrite rule must return a Bassline value')

    if (fixpoint && !out.eq(rebuilt)) {
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
 * @param {...((node: Value) => Value)} rs
 * @returns {(node: Value) => Value}
 */
export function rules(...rs) {
  return node => {
    for (const r of rs) {
      const out = r(node)
      if (!out.eq(node)) return out
    }
    return node
  }
}

/**
 * Match a record whose head is the symbol `name`
 * @param {string} name
 * @param {(node: Value) => Value} fn
 */
export function onHead(name, fn) {
  return rule(head(spelled(name)), fn)
}

/**
 * Match a symbol whose spelling satisfies `pred`.
 * @param { (value: string) => boolean } pred
 * @param {(node: Value) => Value} fn
 */
export function onSymbol(pred, fn) {
  return rule(
    and(kind.symbol, n => pred(n.value)),
    fn
  )
}
