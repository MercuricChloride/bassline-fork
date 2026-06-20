import { fireEvent, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { read } from '@bassline/core/text'
import { testRender } from '~/utils/test-render'
import { DocumentView } from '~/view/hooks'

const show = (src: string) => testRender(<DocumentView doc={read(src)[0]} />)

describe('block — eval seam (append a results directive)', () => {
  it('runs a recognized dialect and shows the result', () => {
    show('<block `{language: "forth"} "10 20 +">')
    fireEvent.click(screen.getByRole('button', { name: /run/i }))
    expect(screen.getByText('result')).toBeInTheDocument()
    expect(screen.getByText('30')).toBeInTheDocument()
  })

  it('renders a pre-computed `results` directive without a Run button', () => {
    show('<block `{language: "forth"} "10 20 +" `{results: 30}>')
    expect(screen.queryByRole('button', { name: /run/i })).toBeNull()
    expect(screen.getByText('30')).toBeInTheDocument()
  })

  it('holds an unknown language inert (custody without comprehension)', () => {
    show('<block `{language: "python"} "print(\'hi\')">')
    expect(screen.queryByRole('button', { name: /run/i })).toBeNull()
    expect(screen.getByText('inert')).toBeInTheDocument()
  })
})
