import { Box, Group, Text } from '@mantine/core'
import { asToken, collect, firstKey } from '../collect'
import { at, kind, sk } from '../match'
import { Children, type NodeProps } from './shared'

export function Document({ node, ctx }: NodeProps) {
  const { directives, content } = collect(node)

  // a directive carrying `theme` -> an inert dict of semantic tokens. The
  // document reconfigures the rendering of its subtree from it.
  const themeDict = firstKey(directives, 'theme')
  const isDict = themeDict !== undefined && kind.dict(themeDict)
  const bg = isDict ? asToken(at(sk('bg'))(themeDict)) : undefined
  const fg = isDict ? asToken(at(sk('text'))(themeDict)) : undefined

  // metadata directives the document chooses to surface; anything else ignored.
  const author = asToken(firstKey(directives, 'author'))
  const date = asToken(firstKey(directives, 'date'))

  return (
    <Box
      style={{
        backgroundColor: bg,
        color: fg,
        padding: 'var(--mantine-spacing-lg)',
        borderRadius: 'var(--mantine-radius-md)',
      }}
    >
      {(author || date) && (
        <Group justify="space-between" mb="md">
          {author && (
            <Text size="sm" c="dimmed">
              {author}
            </Text>
          )}
          {date && (
            <Text size="sm" c="dimmed">
              {date}
            </Text>
          )}
        </Group>
      )}
      <Children items={content} ctx={ctx} />
    </Box>
  )
}
