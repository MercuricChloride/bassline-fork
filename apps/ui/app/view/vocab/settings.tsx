// Settings: enumerate the document's custom bindings and render a control for
// each. This is why def-custom marks bindings "custom" — an options panel can be
// generated from the document without the document naming the controls.
import { Stack, TextInput } from '@mantine/core'
import { str } from '@bassline/core/data'
import type { Binding } from '../bindings'
import { asString, asToken } from '../collect'
import { useBinding, useCustomBindings } from '../hooks'

export function Settings() {
  const customs = useCustomBindings()
  if (customs.length === 0) return null
  return (
    <Stack gap="xs">
      {customs.map(b => (
        <BoundInput key={b.sym.ceKey()} binding={b} />
      ))}
    </Stack>
  )
}

function BoundInput({ binding }: { binding: Binding }) {
  const [value, set] = useBinding(binding.sym)
  return (
    <TextInput
      label={asToken(binding.sym)}
      value={asString(value) ?? ''}
      onChange={e => set(str(e.currentTarget.value))}
    />
  )
}
