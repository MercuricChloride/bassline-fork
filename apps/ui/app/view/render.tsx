// The render core: a total function `render(value, ctx) -> ReactNode`.
//
// It is one `dispatch` over a rule table assembled as
//   base atom/frame rules  ++  vocabulary rules  ++  fallback
// Nothing is unrenderable; recognizing a head is pure enrichment. Adding a node
// type is adding one [predicate, NodeFn] rule to the vocabulary.
import React from 'react'
import type { Value } from '@bassline/core/data'
import type { Rule } from './match'
import { actionable, and, dispatch, kind, or, passive } from './match'
import type { Ctx } from './context'
import { childCtx } from './context'
import { VOCAB } from './vocab'
import { DataView, DirectiveChip, Fallback } from './vocab/fallback'

export type NodeRule = Rule<Ctx, React.ReactNode>

const baseRules: NodeRule[] = [
  [kind.string, v => (kind.string(v) ? v.value : null)],
  [kind.int, v => (kind.int(v) ? String(v.value) : null)],
  [kind.float, v => (kind.float(v) ? String(v.value) : null)],
  [kind.bool, v => (kind.bool(v) ? String(v.value) : null)],
  [kind.symbol, v => (kind.symbol(v) ? v.value : null)],
  [kind.nil, () => null],
  // inert dict = data; actionable dict that reaches a render slot = a directive
  // with no collector, shown rather than silently dropped.
  [and(kind.dict, passive), (v, ctx) => <DataView value={v} ctx={ctx} />],
  [
    and(kind.dict, actionable),
    (v, ctx) => <DirectiveChip value={v} ctx={ctx} />,
  ],
  [or(kind.list, kind.set), (v, ctx) => <Seq value={v} ctx={ctx} />],
]

let dispatcher: ((v: Value, ctx: Ctx) => React.ReactNode) | null = null
function getDispatcher() {
  if (!dispatcher) {
    dispatcher = dispatch<Ctx, React.ReactNode>(
      [...baseRules, ...VOCAB],
      (v, ctx) => <Fallback value={v} ctx={ctx} />
    )
  }
  return dispatcher
}

export function render(value: Value, ctx: Ctx): React.ReactNode {
  return getDispatcher()(value, ctx)
}

/** Render the children of a list/set as a fragment. */
function Seq({ value, ctx }: { value: Value; ctx: Ctx }) {
  const items = kind.list(value) || kind.set(value) ? value.value : []
  const next = childCtx(ctx)
  return (
    <>
      {items.map((c, i) => (
        <React.Fragment key={i}>{render(c, next)}</React.Fragment>
      ))}
    </>
  )
}
