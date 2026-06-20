// Fallback rendering — the bottom of the total function. Any value the
// vocabulary doesn't recognize still renders: a record becomes a labeled,
// inspectable node; an inert dict becomes a key/value view; a stray directive
// becomes a chip. Recognition only ever improves on this.
import { Badge, Box, Code, Group, Stack, Text } from '@mantine/core'
import type { Value } from '@bassline/core/data'
import { print } from '@bassline/core/text'
import { kind } from '../match'
import { collect } from '../collect'
import type { Ctx } from '../context'
import { childCtx } from '../context'
import { render } from '../render'

export function Fallback({ value, ctx }: { value: Value; ctx: Ctx }) {
  if (!kind.record(value)) {
    return <Code>{print(value)}</Code>
  }
  const headName = kind.symbol(value.head)
    ? value.head.value
    : print(value.head)
  const { directives, content } = collect(value)
  const next = childCtx(ctx)
  return (
    <Box
      style={{
        border: '1px dashed var(--mantine-color-gray-4)',
        borderRadius: 'var(--mantine-radius-sm)',
        padding: 'var(--mantine-spacing-xs)',
      }}
    >
      <Group gap="xs" mb={content.length ? 'xs' : 0}>
        <Badge variant="light" color="gray">
          {headName}
        </Badge>
        {directives.map((d, i) => (
          <Code key={i}>{print(d)}</Code>
        ))}
      </Group>
      {content.length > 0 && (
        <Stack gap="xs">
          {content.map((c, i) => (
            <div key={i}>{render(c, next)}</div>
          ))}
        </Stack>
      )}
    </Box>
  )
}

export function DataView({ value, ctx }: { value: Value; ctx: Ctx }) {
  if (!kind.dict(value)) return null
  const next = childCtx(ctx)
  return (
    <Stack gap={2}>
      {[...value].map(([k, v], i) => (
        <Group key={i} gap="xs" align="baseline">
          <Text size="sm" fw={600} c="dimmed">
            {render(k, next)}
          </Text>
          <Text size="sm">{render(v, next)}</Text>
        </Group>
      ))}
    </Stack>
  )
}

export function DirectiveChip({ value }: { value: Value; ctx: Ctx }) {
  return (
    <Badge variant="outline" color="orange" title="uncollected directive">
      {print(value)}
    </Badge>
  )
}
