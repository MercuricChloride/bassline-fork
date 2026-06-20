import { Button as MButton, Select } from '@mantine/core'
import { collect, firstKey } from '../collect'
import { headed } from '../match'
import { firstText, type NodeProps } from './shared'

export function Button({ node, ctx }: NodeProps) {
  const { directives } = collect(node)
  // an `on-click` directive carries a value (a message / actionable program)
  const handler = firstKey(directives, 'on-click')
  return (
    <MButton onClick={handler ? () => ctx.dispatch(handler) : undefined}>
      {firstText(node)}
    </MButton>
  )
}

export function Dropdown({ node }: NodeProps) {
  // dropdown opens a sub-vocabulary: it recognizes `label` and `option` children.
  const { content } = collect(node)
  let label: string | undefined
  const data: string[] = []
  for (const c of content) {
    if (headed('label')(c)) label = firstText(c)
    else if (headed('option')(c)) {
      const opt = firstText(c)
      if (opt !== undefined) data.push(opt)
    }
  }
  return <Select label={label} data={data} placeholder="Select an option" />
}
