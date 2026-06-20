import { Group, Stack as MStack } from '@mantine/core'
import { asToken, collect } from '../collect'
import type { Recognizers } from '../consume'
import { useDirectives } from '../hooks'
import { at, keyed, sk } from '../match'
import { Children, type NodeProps } from './shared'

interface BoxCfg {
  gap: string
}

const boxDirectives: Recognizers<BoxCfg> = [
  [
    keyed(sk('gap')),
    (d, acc, rx) => ({
      ...acc,
      gap: asToken(rx.flat(at(sk('gap'))(d))) ?? acc.gap,
    }),
  ],
]
const boxInit: BoxCfg = { gap: 'md' }

export function Stack({ node }: NodeProps) {
  const { gap } = useDirectives(node, boxDirectives, boxInit)
  return (
    <MStack gap={gap}>
      <Children items={collect(node).content} />
    </MStack>
  )
}

export function Row({ node }: NodeProps) {
  const { gap } = useDirectives(node, boxDirectives, boxInit)
  return (
    <Group gap={gap}>
      <Children items={collect(node).content} />
    </Group>
  )
}
