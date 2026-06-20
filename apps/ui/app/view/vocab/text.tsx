import { Anchor, Text as MText, Title } from '@mantine/core'
import { asNumber, asString, collect, firstKey } from '../collect'
import { Children, firstText, type NodeProps } from './shared'

export function Text({ node, ctx }: NodeProps) {
  const { content } = collect(node)
  return (
    <MText>
      <Children items={content} ctx={ctx} />
    </MText>
  )
}

export function Link({ node, ctx }: NodeProps) {
  const { directives, content } = collect(node)
  const href = asString(firstKey(directives, 'href'))
  return (
    <Anchor href={href} target="_blank" rel="noreferrer">
      <Children items={content} ctx={ctx} />
    </Anchor>
  )
}

export function Heading({ node }: NodeProps) {
  const { directives } = collect(node)
  const level = (asNumber(firstKey(directives, 'level')) ?? 1) as
    | 1
    | 2
    | 3
    | 4
    | 5
    | 6
  return <Title order={level}>{firstText(node)}</Title>
}
