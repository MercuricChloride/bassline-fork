// @ts-check

// Operations over values: walking, the mark predicates, structural rebuild,
// dict / set access, structural similarity, CE-truncation prefixes, and
// shapes with holes. A port of the Nim `lib/ops.nim`, plus the dict / set
// helpers the JS side already had.
//
// `similar` and `prefixes` dispatch on one value and match it against the
// other; they are not visitors and stay plain functions. `walk` is the
// iterative pre-order driver, re-exported from the visitor module.

import { assertValue, eq, isAtom, byValue, BDict, BSet } from './value/value.js'
import { list, record, dict, set, symbol } from './value/build.js'
import { BTree } from './btree.js'
import { walk } from './value/visitor.js'

/**
 * @import { Value, Frame, BList, BRecord } from './value/value.js'
 */

export { walk }

// ================ walking ================

/**
 * The immediate constituents of `v`, in document order. A dict yields
 * key, value, key, value, ...; an atom yields nothing. (Shallow — `walk` is
 * the deep version.)
 * @param {Value} v
 * @yields {Value}
 * @returns {Generator<Value, void>}
 */
export function* items(v) {
  switch (v.kind) {
    case 'list':
    case 'record':
      yield* v.items
      break
    case 'set':
      yield* v.values()
      break
    case 'dict':
      for (const [k, val] of v.entries()) {
        yield k
        yield val
      }
      break
  }
}

/**
 * Every atom in `v`'s tree, in document order.
 * @param {Value} v
 * @yields {Value}
 * @returns {Generator<Value, void>}
 */
export function* atoms(v) {
  for (const node of walk(v)) if (isAtom(node)) yield node
}

// ================ the mark ================

/**
 * Whether `v` itself carries the mark.
 * @param {Value} v
 */
export const marked = v => (assertValue(v), v.mark)

/**
 * Whether the mark appears anywhere in `v`'s tree.
 * @param {Value} v
 */
export function hasMark(v) {
  for (const node of walk(v)) if (node.mark) return true
  return false
}

/**
 * Whether `v` is pure data — nothing in it is marked.
 * @param {Value} v
 */
export const isData = v => (assertValue(v), !hasMark(v))

/**
 * The same value with the mark set as given — a fresh handle over the shared
 * body. A no-op when the mark already matches.
 * @param {Value} v
 * @param {boolean} [on]
 * @returns {Value}
 */
export function withMark(v, on = true) {
  assertValue(v)
  return v.withMark(on)
}

// ================ structural rebuild ================

/**
 * Rebuild a frame by applying `fn` to each constituent — a dict's
 * constituents are `[key, value]` pairs — keeping the mark. An atom is
 * returned unchanged.
 * @param {Value} v
 * @param {((x: Value) => Value) | ((e: [Value, Value]) => [Value, Value])} fn
 * @returns {Value}
 */
export function map(v, fn) {
  const each = /** @type {(x: Value) => Value} */ (fn)
  const eachEntry = /** @type {(e: [Value, Value]) => [Value, Value]} */ (fn)
  switch (v.kind) {
    case 'list':
      return list(v.items.map(each), v.mark)
    case 'record':
      return record(v.items.map(each), v.mark)
    case 'set':
      return set([...v.values()].map(each), v.mark)
    case 'dict':
      return dict([...v.entries()].map(eachEntry), v.mark)
    default:
      return v
  }
}

// ================ dict / set access ================

/**
 * The value under `key` in a dict, or the stored member equal to `key` in a
 * set; `undefined` when it isn't there.
 * @param {BDict | BSet} v
 * @param {Value} key
 * @returns {Value | undefined}
 */
export function at(v, key) {
  if (v.kind === 'dict') return v.get(key)
  if (v.kind === 'set') {
    for (const m of v.values()) if (eq(m, key)) return m
    return undefined
  }
  throw new TypeError('at requires a dictionary or set')
}

/**
 * Whether a dict speaks of `key`, or a set contains it.
 * @param {BDict | BSet} v
 * @param {Value} key
 */
export function contains(v, key) {
  if (v.kind === 'dict' || v.kind === 'set') return v.has(key)
  throw new TypeError('contains requires a dictionary or set')
}

/**
 * A dict with `key` bound to `val`, or a set with `val` added — the rest of
 * the body shared. Overloads: `assoc(dict, key, val)` / `assoc(set, val)`.
 * @param {BDict | BSet} v
 * @param {[Value] | [Value, Value]} args
 * @returns {Value}
 */
export function assoc(v, ...args) {
  if (v.kind === 'dict') {
    const [key, val] = args
    const t = v.tree.clone()
    t.set(key, val)
    return new BDict(t, v.mark)
  }
  if (v.kind === 'set') {
    const s = v.treeSet.clone()
    s.add(args[0])
    return new BSet(s, v.mark)
  }
  throw new TypeError('assoc requires a dictionary or set')
}

/**
 * A dict without `key`, or a set without the member equal to it. Rebuilds the
 * frame (the B+tree has no delete yet).
 * @param {BDict | BSet} v
 * @param {Value} key
 * @returns {Value}
 */
export function dissoc(v, key) {
  if (v.kind === 'dict') {
    return dict(
      [...v.entries()].filter(([k]) => !eq(k, key)),
      v.mark
    )
  }
  if (v.kind === 'set') {
    return set(
      [...v.values()].filter(m => !eq(m, key)),
      v.mark
    )
  }
  throw new TypeError('dissoc requires a dictionary or set')
}

// ================ similarity ================

/**
 * Whether `v` is shaped like `exemplar`: same kind and mark at every node
 * `exemplar` reaches, and a frame in `exemplar` may be shorter than `v`'s
 * (its head must match, for a record). Atoms match on kind and mark alone —
 * `similar` does not look at their payloads.
 * @param {Value} v
 * @param {Value} exemplar
 * @returns {boolean}
 */
export function similar(v, exemplar) {
  assertValue(v)
  assertValue(exemplar)
  if (exemplar.kind !== v.kind || exemplar.mark !== v.mark) return false
  // v.kind === exemplar.kind is now established; narrow v to match.
  switch (exemplar.kind) {
    case 'list': {
      const a = /** @type {BList} */ (v)
      if (exemplar.items.length > a.items.length) return false
      for (let i = 0; i < exemplar.items.length; i++) {
        if (!similar(a.items[i], exemplar.items[i])) return false
      }
      return true
    }
    case 'record': {
      const a = /** @type {BRecord} */ (v)
      if (exemplar.items.length > a.items.length) return false
      if (!eq(exemplar.items[0], a.items[0])) return false
      for (let i = 1; i < exemplar.items.length; i++) {
        if (!similar(a.items[i], exemplar.items[i])) return false
      }
      return true
    }
    case 'dict': {
      const a = /** @type {BDict} */ (v)
      for (const [k, exVal] of exemplar.entries()) {
        const actual = a.get(k)
        if (actual === undefined || !similar(actual, exVal)) return false
      }
      return true
    }
    case 'set': {
      const a = /** @type {BSet} */ (v)
      for (const m of exemplar.values()) if (!a.has(m)) return false
      return true
    }
    default:
      return true // an atom: kind and mark already matched
  }
}

// ================ prefixes ================

/**
 * Whether `a` is a prefix of `b`: what `b`'s canonical encoding yields when
 * stopped early, with every frame the stop left open closed by END. Reflexive.
 * Kind and mark must agree. Among scalars only equal values are prefixes. In a
 * frame every member but the last must equal `b`'s, and the last is itself a
 * prefix of `b`'s. Dicts and sets compare in canonical order, so a prefix is a
 * leading run of the sorted members, not a subset.
 * @param {Value} a
 * @param {Value} b
 * @returns {boolean}
 */
export function prefixes(a, b) {
  assertValue(a)
  assertValue(b)
  if (a.kind !== b.kind || a.mark !== b.mark) return false
  if (a.isAtom()) return a.equals(b)
  // a frame, and b is the same kind: members() is the flat member sequence
  // (key, value, key, value for a dict), so `a` is a prefix of `b` when every
  // member but its last equals b's and the last is itself a prefix of b's.
  const am = [...a.members()]
  const bm = [.../** @type {Frame} */ (b).members()]
  if (am.length > bm.length) return false
  for (let i = 0; i < am.length; i++) {
    const last = i + 1 === am.length
    if (!(last ? prefixes(am[i], bm[i]) : am[i].equals(bm[i]))) return false
  }
  return true
}

// ================ shapes ================
//
// A shape is a value with holes. A hole is a marked atom, and the atom is its
// name; `_!` binds nothing. `extract` recognises a value by a shape — literal
// parts must match exactly — and binds the holes into a dict keyed by their
// names. A hole seen twice must bind the same value. `inject` fills a shape's
// holes from bindings, leaving unbound holes in place, so filling composes. A
// hole in a dict key or set member has no single answer, so `extract` refuses
// such shapes.

const ANON = symbol('_', true)

/**
 * Whether `v` is a hole: a marked atom.
 * @param {Value} v
 */
export const isHole = v => v.mark && isAtom(v)

/**
 * Whether `v` is the anonymous hole `_!`.
 * @param {Value} v
 */
export const isAnon = v => v.equals(ANON)

/**
 * Whether a hole appears anywhere in `v`.
 * @param {Value} v
 */
export function hasHoles(v) {
  if (isHole(v)) return true
  for (const c of items(v)) if (hasHoles(c)) return true
  return false
}

/**
 * @param {Value} shape
 * @param {Value} value
 * @param {BTree<Value, Value>} bindings
 * @returns {boolean}
 */
function matchShape(shape, value, bindings) {
  if (isHole(shape)) {
    if (isAnon(shape)) return true
    const name = shape.withMark(false)
    const existing = bindings.get(name)
    if (existing !== undefined) return existing.equals(value)
    bindings.set(name, value)
    return true
  }
  if (shape.kind !== value.kind || shape.mark !== value.mark) return false
  switch (shape.kind) {
    case 'list':
    case 'record': {
      const vv = /** @type {BList | BRecord} */ (value)
      if (shape.items.length !== vv.items.length) return false
      for (let i = 0; i < shape.items.length; i++) {
        if (!matchShape(shape.items[i], vv.items[i], bindings)) return false
      }
      return true
    }
    case 'dict': {
      const vv = /** @type {BDict} */ (value)
      for (const [k, sv] of shape.entries()) {
        if (hasHoles(k)) {
          throw new Error('a hole in a dict key is not supported')
        }
        const av = vv.get(k)
        if (av === undefined || !matchShape(sv, av, bindings)) return false
      }
      return true
    }
    case 'set': {
      for (const m of shape.values()) {
        if (hasHoles(m)) {
          throw new Error('a hole in a set member is not supported')
        }
      }
      return shape.equals(value)
    }
    default:
      return shape.equals(value)
  }
}

/**
 * Recognise `value` by `shape` and bind its holes. Returns a dict keyed by
 * the holes' names, or `undefined` when the shape does not match.
 * @param {Value} shape
 * @param {Value} value
 * @returns {BDict | undefined}
 */
export function extract(shape, value) {
  assertValue(shape)
  assertValue(value)
  /** @type {BTree<Value, Value>} */
  const bindings = new BTree(byValue)
  if (!matchShape(shape, value, bindings)) return undefined
  return new BDict(bindings, false)
}

/**
 * `shape` with its holes filled from `bindings` (a dict keyed by hole name).
 * A hole with no binding is left in place.
 * @param {Value} shape
 * @param {Value} bindings
 * @returns {Value}
 */
export function inject(shape, bindings) {
  assertValue(shape)
  assertValue(bindings)
  if (isHole(shape)) {
    if (isAnon(shape)) return shape
    if (bindings.kind === 'dict') {
      const bound = bindings.get(shape.withMark(false))
      if (bound !== undefined) return bound
    }
    return shape
  }
  switch (shape.kind) {
    case 'list':
      return list(
        [...shape.items].map(c => inject(c, bindings)),
        shape.mark
      )
    case 'record':
      return record(
        [...shape.items].map(c => inject(c, bindings)),
        shape.mark
      )
    case 'dict':
      return dict(
        [...shape.entries()].map(([k, v]) => [
          inject(k, bindings),
          inject(v, bindings),
        ]),
        shape.mark
      )
    case 'set':
      return set(
        [...shape.values()].map(m => inject(m, bindings)),
        shape.mark
      )
    default:
      return shape
  }
}
