// The render core: a total function, now a component `<Render value/>`.
//
// It is one ordered rule table: base atom/frame rules ++ vocabulary rules ++
// fallback. Nothing is unrenderable; recognizing a head is pure enrichment.
// Context (bindings, dispatch) flows through React context — nodes pull what
// they need via hooks, so there is no manual ctx threading.
import React, { type ReactNode } from 'react'
import type { Value } from '@bassline/core/data'
import {
  actionable,
  and,
  headed,
  kind,
  or,
  passive,
  type Predicate,
} from './match'
import { useResolve } from './hooks'
import { VOCAB } from './vocab'
import { DataView, DirectiveChip, Fallback } from './vocab/fallback'

export type NodeRule = [Predicate, (v: Value) => ReactNode]

const baseRules: NodeRule[] = [
  [kind.string, v => (kind.string(v) ? v.value : null)],
  [kind.int, v => (kind.int(v) ? String(v.value) : null)],
  [kind.float, v => (kind.float(v) ? String(v.value) : null)],
  [kind.bool, v => (kind.bool(v) ? String(v.value) : null)],
  [kind.nil, () => null],
  // a marked symbol is a dereference
  [and(kind.symbol, actionable), v => <Ref symbol={v} />],
  [kind.symbol, v => (kind.symbol(v) ? v.value : null)],
  // binding directives that reach a render slot produce no UI — they act on the
  // store (seeded / dispatched), they are not content.
  [or(headed('def-custom'), headed('set')), () => null],
  // inert dict = data; a stray actionable dict is a directive without a collector
  [and(kind.dict, passive), v => <DataView value={v} />],
  [and(kind.dict, actionable), v => <DirectiveChip value={v} />],
  [or(kind.list, kind.set), v => <Seq value={v} />],
]

const rules: NodeRule[] = [...baseRules, ...VOCAB]

export function Render({ value }: { value: Value }): ReactNode {
  for (const [pred, fn] of rules) {
    if (pred(value)) return fn(value)
  }
  return <Fallback value={value} />
}

/** A marked symbol: resolve it against the live store and render the result. */
function Ref({ symbol }: { symbol: Value }) {
  const resolve = useResolve()
  return <Render value={resolve(symbol)} />
}

/** Render the children of a list/set as a fragment. */
function Seq({ value }: { value: Value }) {
  const items = kind.list(value) || kind.set(value) ? value.value : []
  return (
    <>
      {items.map((c, i) => (
        <React.Fragment key={i}>
          <Render value={c} />
        </React.Fragment>
      ))}
    </>
  )
}
