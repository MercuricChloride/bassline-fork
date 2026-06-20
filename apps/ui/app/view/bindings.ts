// Document bindings — a single, flat namespace, indexed by a symbol's canonical
// encoding. There is no lexical scope: `<def-custom name default>` anywhere in a
// document declares the same binding, which is what lets us enumerate them.
//
// Two binding directives:
//   `<def-custom name default>  idempotent: bind name to default IF not already
//                                bound. Marks the binding "custom" (enumerable).
//   `<set name value>            imperative: bind name to value.
// And dereference:
//   `name                        a marked symbol resolves to its bound value.
//
// This is the view layer's own small semantics — deliberately separate from the
// lang evaluator, which does richer things.
import type { Value } from '@bassline/core/data'
import { record, sym } from '@bassline/core/data'
import { kind } from '@bassline/core/match'
import { rewrite } from '@bassline/core/lang'
import { headed } from './match'

export interface Binding {
  /** the binding's name as an (inert) symbol */
  sym: Value
  /** current bound value */
  value: Value
  /** declared via def-custom (enumerable as an option) */
  custom: boolean
  /** the declared default, if any */
  def?: Value
}

/** A binding store, keyed by the name symbol's static canonical encoding. */
export type Store = Map<string, Binding>

/**
 * Key a name symbol independent of its mark, so the inert name in
 * `<def-custom greeting …>` and the marked reference `` `greeting `` collide.
 * For symbols we re-mint an inert symbol from the value; other key kinds use
 * their own canonical bytes.
 */
export const keyOf = (s: Value): string =>
  kind.symbol(s) ? sym(s.value).ceKey() : s.ceKey()

/** The inert name symbol for a binding (display/enumeration form). */
export const nameOf = (s: Value): Value => (kind.symbol(s) ? sym(s.value) : s)

/** A reference value: a marked symbol that dereferences to its binding. */
export const ref = (name: string): Value => sym(name).toActionable() as Value

export const unbound = (name: Value): Value =>
  record(sym('error'), sym('unbound'), nameOf(name))

/** Walk a value tree, seeding the store from every `def-custom` declaration. */
export function seed(doc: Value): Store {
  const store: Store = new Map()
  const visit = (v: Value) => {
    if (headed('def-custom')(v) && kind.record(v)) {
      const [name, def] = v.fields
      if (name && kind.symbol(name)) {
        const k = keyOf(name)
        if (!store.has(k)) {
          store.set(k, {
            sym: nameOf(name),
            value: def ?? name,
            custom: true,
            def,
          })
        }
      }
    }
    if (kind.record(v)) v.fields.forEach(visit)
    else if (kind.list(v) || kind.set(v)) v.value.forEach(visit)
    else if (kind.dict(v)) for (const [k, val] of v) (visit(k), visit(val))
  }
  visit(doc)
  return store
}

/** Resolve a value: a marked symbol dereferences; everything else is itself. */
export function resolve(v: Value, store: Store): Value {
  if (kind.symbol(v) && v.actionable) {
    const b = store.get(keyOf(v))
    return b ? b.value : unbound(v)
  }
  return v
}

/**
 * Deep resolution: dereference every marked symbol anywhere in the value tree.
 * This is just the flat `resolve` rule driven over the whole tree by the generic
 * `rewrite` — resolution is a rule applied at a chosen depth, not a special pass.
 */
export const resolveDeep = (v: Value, store: Store): Value =>
  rewrite(v, node => resolve(node, store))
