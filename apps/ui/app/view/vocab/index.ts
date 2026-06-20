// The vocabulary: an ordered table of [predicate, NodeFn] rules. Specific rules
// come before general ones (first match wins). Adding a node type = adding a
// rule here; unrecognized heads fall through to the Fallback.
import { createElement, type ReactNode } from 'react'
import type { Value } from '@bassline/core/data'
import { headed } from '../match'
import type { NodeRule } from '../render'
import { Block } from './block'
import { Button, Dropdown } from './controls'
import { Document } from './document'
import { Row, Stack } from './layout'
import { Settings } from './settings'
import type { NodeProps } from './shared'
import { Heading, Link, Text } from './text'

const node =
  (Comp: (p: NodeProps) => ReactNode) =>
  (v: Value): ReactNode =>
    createElement(Comp, { node: v })

export const VOCAB: NodeRule[] = [
  [headed('document'), node(Document)],
  [headed('stack'), node(Stack)],
  [headed('row'), node(Row)],
  [headed('heading'), node(Heading)],
  [headed('text'), node(Text)],
  [headed('link'), node(Link)],
  [headed('button'), node(Button)],
  [headed('dropdown'), node(Dropdown)],
  [headed('settings'), node(Settings)],
  [headed('block'), node(Block)],
]
