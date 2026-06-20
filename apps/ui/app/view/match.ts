// Recognition combinators for the view layer.
//
// Built on @bassline/core/match (re-exported below). Everything here stays in
// Data-land: dict keys are arbitrary `Value`s, looked up by value — never by
// flattening a dict into a JS object keyed by string.
import type { Value } from '@bassline/core/data'
import type { Predicate } from '@bassline/core/match'
import { sym } from '@bassline/core/data'
import { head, kind, spelled } from '@bassline/core/match'

export * from '@bassline/core/match'

/** A render/dispatch rule: a predicate paired with a handler. */
export type Rule<C, R> = [Predicate, (v: Value, ctx: C) => R]

/** Cached symbol keys — the common dict-key case in current documents. */
const symKeys = new Map<string, Value>()

/** A symbol key, e.g. `at(sk("href"))`. Cached so repeated lookups are cheap. */
export function sk(name: string): Value {
  let s = symKeys.get(name)
  if (!s) {
    s = sym(name)
    symKeys.set(name, s)
  }
  return s
}

/**
 * Extract a value from a dict by `Value` key. Returns `undefined` for non-dicts
 * or missing keys. Honors arbitrary keys (not just symbols).
 */
export const at =
  (key: Value) =>
  (v: Value): Value | undefined =>
    kind.dict(v) ? v.get(key) : undefined

/** Predicate: a dict that has `key` (and whose value matches `valPred`, if given). */
export const keyed =
  (key: Value, valPred?: Predicate): Predicate =>
  (v: Value) => {
    const found = at(key)(v)
    if (found === undefined) return false
    return valPred ? valPred(found) : true
  }

/** Predicate: a record whose head is the symbol `name`. `head(spelled(name))`. */
export const headed = (name: string): Predicate => head(spelled(name))

/**
 * The rendering cousin of `match`: first matching rule wins, else `fallback`.
 * Unlike `match` (Value -> Value, identity default) this returns an arbitrary
 * `R` and requires an explicit fallback. This is the single extensibility seam.
 */
export function dispatch<C, R>(
  rules: Rule<C, R>[],
  fallback: (v: Value, ctx: C) => R
): (v: Value, ctx: C) => R {
  return (v, ctx) => {
    for (const [p, f] of rules) {
      if (p(v)) return f(v, ctx)
    }
    return fallback(v, ctx)
  }
}
