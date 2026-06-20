import { Button as MButton, Select } from '@mantine/core'
import { str, type Value } from '@bassline/core/data'
import { asString, collect } from '../collect'
import { recognize, type Recognizers } from '../consume'
import { useBinding, useDirectives, useDispatch, useRx } from '../hooks'
import { at, headed, keyed, sk } from '../match'
import { firstText, type NodeProps } from './shared'

// ---- button -----------------------------------------------------------------

interface ButtonCfg {
  onClick?: Value
}
const buttonDirectives: Recognizers<ButtonCfg> = [
  // raw: an on-click is a deferred program, resolved at dispatch, not now
  [
    keyed(sk('on-click')),
    (d, acc, rx) => ({ ...acc, onClick: rx.raw(at(sk('on-click'))(d)) }),
  ],
]
const buttonInit: ButtonCfg = {}

export function Button({ node }: NodeProps) {
  const { onClick } = useDirectives(node, buttonDirectives, buttonInit)
  const dispatch = useDispatch()
  return (
    <MButton onClick={onClick ? () => dispatch(onClick) : undefined}>
      {firstText(node)}
    </MButton>
  )
}

// ---- dropdown ---------------------------------------------------------------

interface DropdownCfg {
  bind?: Value // the binding NAME symbol (raw — not dereferenced)
}
const dropdownDirectives: Recognizers<DropdownCfg> = [
  [
    keyed(sk('bind')),
    (d, acc, rx) => ({ ...acc, bind: rx.raw(at(sk('bind'))(d)) }),
  ],
]
const dropdownInit: DropdownCfg = {}

interface DropdownContent {
  label?: string
  options: string[]
}
const dropdownContent: Recognizers<DropdownContent> = [
  [headed('label'), (c, acc) => ({ ...acc, label: firstText(c) })],
  [
    headed('option'),
    (c, acc) => {
      const o = firstText(c)
      return o === undefined ? acc : { ...acc, options: [...acc.options, o] }
    },
  ],
]

export function Dropdown({ node }: NodeProps) {
  const { bind } = useDirectives(node, dropdownDirectives, dropdownInit)
  const { label, options } = recognize(
    collect(node).content,
    dropdownContent,
    { options: [] },
    useRx()
  )
  return bind ? (
    <BoundSelect name={bind} label={label} options={options} />
  ) : (
    <Select label={label} data={options} placeholder="Select an option" />
  )
}

function BoundSelect({
  name,
  label,
  options,
}: {
  name: Value
  label?: string
  options: string[]
}) {
  const [value, set] = useBinding(name)
  return (
    <Select
      label={label}
      data={options}
      value={asString(value) ?? null}
      onChange={v => set(str(v ?? ''))}
    />
  )
}
