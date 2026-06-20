import { useState } from 'react'
import { Badge, Button, Code, Group, Stack } from '@mantine/core'
import { BasslineDict, record, sym, type Value } from '@bassline/core/data'
import { asString, collect, firstKey } from '../collect'
import { childCtx } from '../context'
import { dialectFor } from '../dialects'
import { kind } from '../match'
import { render } from '../render'
import type { NodeProps } from './shared'

export function Block({ node, ctx }: NodeProps) {
  // local document state: running appends a `{results}` directive, producing a
  // new block value that we re-render. document <-> program <-> document.
  const [current, setCurrent] = useState<Value>(node)
  if (!kind.record(current)) return null

  const { directives, content } = collect(current)
  const lang = asString(firstKey(directives, 'language'))
  const cached = firstKey(directives, 'results')
  const source = content.map(asString).find(s => s !== undefined) ?? ''
  const dialect = dialectFor(lang)
  const next = childCtx(ctx)

  const run = () => {
    if (!dialect) return
    const result = dialect(source, ctx)
    const resultDirective = new BasslineDict([[sym('results'), result]], true)
    const updated = record(current.head, ...current.fields, resultDirective)
    setCurrent(updated)
    ctx.dispatch(updated)
  }

  return (
    <Stack gap="xs">
      <Group gap="xs">
        <Badge variant="light">{lang ?? 'text'}</Badge>
        {dialect && cached === undefined && (
          <Button size="xs" variant="light" onClick={run}>
            Run
          </Button>
        )}
        {!dialect && lang && (
          <Badge
            color="gray"
            variant="outline"
            title="no dialect — held, not run"
          >
            inert
          </Badge>
        )}
      </Group>
      <Code block>{source}</Code>
      {cached !== undefined && (
        <Group gap="xs">
          <Badge color="green" variant="light">
            result
          </Badge>
          <Code>{render(cached, next)}</Code>
        </Group>
      )}
    </Stack>
  )
}
