// Consumption: run a recognition table over a *stream* of values (a node's
// directives or its content), folding each recognized value into an accumulator.
// This is the flat cousin of `rewrite` (deep) — the same [predicate, handler]
// shape, applied once per element instead of across a tree.
//
// Resolution depth is chosen per value via `rx` — "does this consumer consume
// deep, flat, or raw" — so config refs resolve while deferred handlers don't.
import type { Value } from '@bassline/core/data'
import type { Predicate } from './match'
import { resolve, resolveDeep, type Store } from './bindings'

/** Per-value resolution at a chosen depth. */
export interface Rx {
  /** dereference a top-level ref */
  flat: (v: Value | undefined) => Value | undefined
  /** dereference every ref in the value tree */
  deep: (v: Value | undefined) => Value | undefined
  /** leave refs unresolved — for deferred handlers / programs */
  raw: (v: Value | undefined) => Value | undefined
}

export const makeRx = (store: Store): Rx => ({
  flat: v => (v === undefined ? undefined : resolve(v, store)),
  deep: v => (v === undefined ? undefined : resolveDeep(v, store)),
  raw: v => v,
})

/** A fold step for one recognized value: returns the next accumulator. */
export type Step<T> = (v: Value, acc: T, rx: Rx) => T

/** A recognition table over a value stream. */
export type Recognizers<T> = Array<[Predicate, Step<T>]>

/**
 * Fold a recognition table over a value stream. Each value runs EVERY rule whose
 * predicate matches (not just the first) — one directive dict can carry several
 * keys, so several rules may fire; mutually-exclusive predicates (e.g. label vs
 * option) behave like first-match anyway. Unrecognized values are skipped.
 * Whether a step "merges" is the node's own choice — there is no global merge.
 */
export function recognize<T>(
  values: Value[],
  table: Recognizers<T>,
  init: T,
  rx: Rx
): T {
  let acc = init
  for (const v of values) {
    for (const [pred, step] of table) {
      if (pred(v)) acc = step(v, acc, rx)
    }
  }
  return acc
}
