import { fireEvent, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { read } from '@bassline/core/text'
import bindingsDoc from '../../public/examples/bindings.blt?raw'
import { testRender } from '~/utils/test-render'
import { DocumentView } from '~/view/hooks'

describe('dropdown bound to a binding', () => {
  it('reflects the binding default and writes it on selection', () => {
    const { container } = testRender(
      <DocumentView doc={read(bindingsDoc)[0]} />
    )
    expect(container.textContent).toContain('You picked: one') // def-custom pick "one"

    fireEvent.click(screen.getByRole('combobox', { name: 'Pick one' })) // open the select
    fireEvent.click(screen.getByRole('option', { name: 'two' }))
    expect(container.textContent).toContain('You picked: two') // ref re-rendered
  })
})
