import { Group, Stack as MStack } from '@mantine/core'
import { asToken, collect, firstKey } from '../collect'
import { Children, type NodeProps } from './shared'

export function Stack({ node, ctx }: NodeProps) {
  const { directives, content } = collect(node)
  const gap = asToken(firstKey(directives, 'gap')) ?? 'md'
  return (
    <MStack gap={gap}>
      <Children items={content} ctx={ctx} />
    </MStack>
  )
}

export function Row({ node, ctx }: NodeProps) {
  const { directives, content } = collect(node)
  const gap = asToken(firstKey(directives, 'gap')) ?? 'md'
  return (
    <Group gap={gap}>
      <Children items={content} ctx={ctx} />
    </Group>
  )
}
