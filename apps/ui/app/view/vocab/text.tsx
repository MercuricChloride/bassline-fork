import { Anchor, Text as MText, Title } from '@mantine/core'
import { asNumber, asString, collect } from '../collect'
import type { Recognizers } from '../consume'
import { useDirectives } from '../hooks'
import { at, keyed, sk } from '../match'
import { Children, firstText, type NodeProps } from './shared'

export function Text({ node }: NodeProps) {
  return (
    <MText>
      <Children items={collect(node).content} />
    </MText>
  )
}

interface LinkCfg {
  href?: string
}
const linkDirectives: Recognizers<LinkCfg> = [
  [
    keyed(sk('href')),
    (d, acc, rx) => ({ ...acc, href: asString(rx.flat(at(sk('href'))(d))) }),
  ],
]
const linkInit: LinkCfg = {}

export function Link({ node }: NodeProps) {
  const { href } = useDirectives(node, linkDirectives, linkInit)
  return (
    <Anchor href={href} target="_blank" rel="noreferrer">
      <Children items={collect(node).content} />
    </Anchor>
  )
}

type Level = 1 | 2 | 3 | 4 | 5 | 6
interface HeadingCfg {
  level: Level
}
const headingDirectives: Recognizers<HeadingCfg> = [
  [
    keyed(sk('level')),
    (d, acc, rx) => ({
      ...acc,
      level: (asNumber(rx.flat(at(sk('level'))(d))) ?? 1) as Level,
    }),
  ],
]
const headingInit: HeadingCfg = { level: 1 }

export function Heading({ node }: NodeProps) {
  const { level } = useDirectives(node, headingDirectives, headingInit)
  return <Title order={level}>{firstText(node)}</Title>
}
