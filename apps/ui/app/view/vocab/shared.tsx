import React from 'react'
import type { Value } from '@bassline/core/data'
import { asString, collect } from '../collect'
import { kind } from '../match'
import { Render } from '../render'

export interface NodeProps {
  node: Value
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
export function Children({ items }: { items: Value[] }) {
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
