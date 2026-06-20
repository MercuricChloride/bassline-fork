import { useState } from 'react'
import { Badge, Button, Code, Group, Stack } from '@mantine/core'
import type { Value } from '@bassline/core/data'
import { asString, collect } from '../collect'
import type { Recognizers } from '../consume'
import { useDialect, useDirectives } from '../hooks'
import { at, keyed, sk } from '../match'
import { Render } from '../render'
import type { NodeProps } from './shared'

interface BlockCfg {
  language?: string
  results?: Value
}
const blockDirectives: Recognizers<BlockCfg> = [
  [
    keyed(sk('language')),
    (d, acc, rx) => ({
      ...acc,
      language: asString(rx.flat(at(sk('language'))(d))),
    }),
  ],
  [
    keyed(sk('results')),
    (d, acc, rx) => ({ ...acc, results: rx.flat(at(sk('results'))(d)) }),
  ],
]
const blockInit: BlockCfg = {}

export function Block({ node }: NodeProps) {
  const { language, results: cached } = useDirectives(
    node,
    blockDirectives,
    blockInit
  )
  const dialect = useDialect(language)
  // a run result lives locally (document <-> program <-> document); a `results`
  // directive already in the document is the cached form.
  const [ran, setRan] = useState<Value | undefined>(undefined)
  const result = ran ?? cached
  const source =
    collect(node)
      .content.map(asString)
      .find(s => s !== undefined) ?? ''

  const run = () => {
    if (dialect) setRan(dialect(source))
  }

  return (
    <Stack gap="xs">
      <Group gap="xs">
        <Badge variant="light">{language ?? 'text'}</Badge>
        {dialect && result === undefined && (
          <Button size="xs" variant="light" onClick={run}>
            Run
          </Button>
        )}
        {!dialect && language && (
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
      {result !== undefined && (
        <Group gap="xs">
          <Badge color="green" variant="light">
            result
          </Badge>
          <Code>
            <Render value={result} />
          </Code>
        </Group>
      )}
    </Stack>
  )
}
