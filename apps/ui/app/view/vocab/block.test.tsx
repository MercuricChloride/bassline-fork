import { fireEvent, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { read } from '@bassline/core/text'
import { testRender } from '~/utils/test-render'
import { defaultCtx } from '../context'
import { render } from '../render'

describe('block — eval seam (append a results directive)', () => {
  it('runs a recognized dialect and shows the result', () => {
    const block = read('<block `{language: "forth"} "10 20 +">')[0]
    testRender(render(block, defaultCtx))
    fireEvent.click(screen.getByRole('button', { name: /run/i }))
    expect(screen.getByText('result')).toBeInTheDocument()
    expect(screen.getByText('30')).toBeInTheDocument()
  })

  it('renders a pre-computed `results` directive without a Run button', () => {
    const block = read(
      '<block `{language: "forth"} "10 20 +" `{results: 30}>'
    )[0]
    testRender(render(block, defaultCtx))
    expect(screen.queryByRole('button', { name: /run/i })).toBeNull()
    expect(screen.getByText('30')).toBeInTheDocument()
  })

  it('holds an unknown language inert (custody without comprehension)', () => {
    const block = read('<block `{language: "python"} "print(\'hi\')">')[0]
    testRender(render(block, defaultCtx))
    expect(screen.queryByRole('button', { name: /run/i })).toBeNull()
    expect(screen.getByText('inert')).toBeInTheDocument()
  })
})
