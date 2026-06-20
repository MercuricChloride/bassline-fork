import { fireEvent, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { read } from '@bassline/core/text'
import { testRender } from '~/utils/test-render'
import { DocumentView } from '~/view/hooks'

// src starts "A"; button-1 sets src to "B"; button-2 sets out to `src (a ref).
// If on-click were resolved at render, button-2 would capture src="A" and out
// would become "A". Because commands resolve args at DISPATCH time, clicking
// button-1 then button-2 yields out="B" — proving deferred resolution.
const doc = `<document
  \`<def-custom src "A">
  \`<def-custom out "none">
  <stack
    <button \`{on-click: \`<set src "B">} "make B">
    <button \`{on-click: \`<set out \`src>} "capture">
    <text "out=" \`out>
  >
>`

describe('commands — on-click resolves at dispatch, not render', () => {
  it('captures the current binding at click time', () => {
    const { container } = testRender(<DocumentView doc={read(doc)[0]} />)
    expect(container.textContent).toContain('out=none')

    fireEvent.click(screen.getByRole('button', { name: /make b/i }))
    fireEvent.click(screen.getByRole('button', { name: /capture/i }))
    expect(container.textContent).toContain('out=B') // not "A"
  })
})
