/** @import { Value } from '../data.js' */
import { assertValue } from '../data.js'

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
  /** @param {Value} aNode */
  function rebuild(aNode) {
    switch (aNode.kind) {
      case 'dict':
        return aNode.map(([k, v]) => [go(k), go(v)])
      case 'record':
      case 'list':
      case 'set':
        return aNode.map(go)
      default:
        return aNode
    }
  }
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
 * Try each rule in order; the first that changes the node is returned, or the original node if none do.
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
