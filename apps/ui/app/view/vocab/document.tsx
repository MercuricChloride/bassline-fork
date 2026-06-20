import { Box, Group, Text } from '@mantine/core'
import { asToken, collect } from '../collect'
import type { Recognizers } from '../consume'
import { useDirectives } from '../hooks'
import { at, kind, keyed, sk } from '../match'
import { Children, type NodeProps } from './shared'

interface DocCfg {
  bg?: string
  fg?: string
  author?: string
  date?: string
}

const docDirectives: Recognizers<DocCfg> = [
  // a `theme` directive carries an inert dict of semantic tokens
  [
    keyed(sk('theme')),
    (d, acc, rx) => {
      const theme = rx.flat(at(sk('theme'))(d))
      if (!theme || !kind.dict(theme)) return acc
      return {
        ...acc,
        bg: asToken(at(sk('bg'))(theme)),
        fg: asToken(at(sk('text'))(theme)),
      }
    },
  ],
  [
    keyed(sk('author')),
    (d, acc, rx) => ({ ...acc, author: asToken(rx.flat(at(sk('author'))(d))) }),
  ],
  [
    keyed(sk('date')),
    (d, acc, rx) => ({ ...acc, date: asToken(rx.flat(at(sk('date'))(d))) }),
  ],
]
const docInit: DocCfg = {}

export function Document({ node }: NodeProps) {
  const { bg, fg, author, date } = useDirectives(node, docDirectives, docInit)
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
      <Children items={collect(node).content} />
    </Box>
  )
}
