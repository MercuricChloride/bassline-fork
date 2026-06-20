// Fallback rendering — the bottom of the total function. Any value the
// vocabulary doesn't recognize still renders: a record becomes a labeled,
// inspectable node; an inert dict becomes a key/value view; a stray directive
// becomes a chip. Recognition only ever improves on this.
import { Badge, Box, Code, Group, Stack, Text } from '@mantine/core'
import type { Value } from '@bassline/core/data'
import { print } from '@bassline/core/text'
import { collect } from '../collect'
import { kind } from '../match'
import { Render } from '../render'

export function Fallback({ value }: { value: Value }) {
  if (!kind.record(value)) {
    return <Code>{print(value)}</Code>
  }
  const headName = kind.symbol(value.head)
    ? value.head.value
    : print(value.head)
  const { directives, content } = collect(value)
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
            <div key={i}>
              <Render value={c} />
            </div>
          ))}
        </Stack>
      )}
    </Box>
  )
}

export function DataView({ value }: { value: Value }) {
  if (!kind.dict(value)) return null
  return (
    <Stack gap={2}>
      {[...value].map(([k, v], i) => (
        <Group key={i} gap="xs" align="baseline">
          <Text size="sm" fw={600} c="dimmed">
            <Render value={k} />
          </Text>
          <Text size="sm">
            <Render value={v} />
          </Text>
        </Group>
      ))}
    </Stack>
  )
}

export function DirectiveChip({ value }: { value: Value }) {
  return (
    <Badge variant="outline" color="orange" title="uncollected directive">
      {print(value)}
    </Badge>
  )
}
