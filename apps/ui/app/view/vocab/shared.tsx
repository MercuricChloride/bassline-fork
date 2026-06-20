import React from 'react'
import type { Value } from '@bassline/core/data'
import { asString, collect } from '../collect'
import type { Ctx } from '../context'
import { childCtx } from '../context'
import { kind } from '../match'
import { render } from '../render'

export interface NodeProps {
  node: Value
  ctx: Ctx
}

/** First string among a node's content children (its "label"/"text"). */
export function firstText(node: Value): string | undefined {
  if (!kind.record(node)) return undefined
  const { content } = collect(node)
  for (const c of content) {
    const s = asString(c)
    if (s !== undefined) return s
  }
  return undefined
}

/** Render a content array, each child keyed. */
export function Children({ items, ctx }: { items: Value[]; ctx: Ctx }) {
  const next = childCtx(ctx)
  return (
    <>
      {items.map((c, i) => (
        <React.Fragment key={i}>{render(c, next)}</React.Fragment>
      ))}
    </>
  )
}
