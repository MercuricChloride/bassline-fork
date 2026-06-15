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

import {
  list,
  dict,
  record,
  set,
  isValue,
  eq,
  BasslineList,
  BasslineDict,
  BasslineRecord,
  BasslineSet,
  BasslineSymbol,
} from '../data.js'

/**
 * The ordered constituents of a value (atoms have none).
 * @param v
 */
export function children(v) {
  if (v instanceof BasslineList) return v.value
  if (v instanceof BasslineSet) return v.value
  if (v instanceof BasslineRecord) return [v.head, ...v.fields]
  if (v instanceof BasslineDict) return v.value.flatMap(([k, val]) => [k, val])
  return []
}

/**
 * Carry the actionable bit of the original onto a freshly built value.
 * @param orig
 * @param built
 */
const like = (orig, built) => (orig.actionable ? built.toActionable() : built)

/**
 * Rebuild a value of the same shape from new children — the inverse of
 * children(). Atoms have no children and are returned unchanged.
 * @param v
 * @param kids
 */
export function rebuild(v, kids) {
  if (v instanceof BasslineList) return like(v, list(kids))
  if (v instanceof BasslineSet) return like(v, set(kids))
  if (v instanceof BasslineRecord)
    return like(v, record(kids[0], kids.slice(1)))
  if (v instanceof BasslineDict) {
    if (kids.length % 2 !== 0)
      throw new Error('rebuild: dict needs an even number of children')
    const entries = []
    for (let i = 0; i < kids.length; i += 2)
      entries.push([kids[i], kids[i + 1]])
    return like(v, dict(entries))
  }
  return v
}

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
    const kids = children(node)
    const rebuilt = kids.length ? rebuild(node, kids.map(go)) : node
    const out = rule(rebuilt)
    if (!isValue(out))
      throw new TypeError('a rewrite rule must return a Bassline value')
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
 * @param {...any} rs
 */
export const rules =
  (...rs) =>
  node => {
    for (const r of rs) {
      const out = r(node)
      if (!eq(out, node)) return out
    }
    return node
  }

/**
 * Match a record whose head is the symbol `name` (ignores the actionable bit).
 * @param name
 * @param fn
 */
export const onHead = (name, fn) => node =>
  node instanceof BasslineRecord &&
  node.head instanceof BasslineSymbol &&
  node.head.value === name
    ? fn(node)
    : node

/**
 * Match a symbol whose spelling satisfies `pred`.
 * @param pred
 * @param fn
 */
export const onSymbol = (pred, fn) => node =>
  node instanceof BasslineSymbol && pred(node.value) ? fn(node) : node
