import { screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { read } from '@bassline/core/text'
import docSource from '../../public/document.blt?raw'
import { testRender } from '~/utils/test-render'
import { DocumentView } from '~/view/hooks'

const doc = read(docSource)[0]
const show = () => testRender(<DocumentView doc={doc} />)

describe('render — total function over the document', () => {
  it('renders the whole document without throwing (generic fallback)', () => {
    expect(() => show()).not.toThrow()
  })

  it('renders recognized vocabulary as real widgets', () => {
    show()
    // button -> Mantine Button
    expect(
      screen.getByRole('button', { name: /click me/i })
    ).toBeInTheDocument()
    // link -> Anchor with href directive
    const link = screen.getByRole('link', { name: /example/i })
    expect(link).toHaveAttribute('href', 'https://example.com')
    // dropdown -> Select with its label
    expect(screen.getByText(/select an option/i)).toBeInTheDocument()
  })

  it('renders blocks: cached forth result and an inert python block', () => {
    show()
    expect(screen.getByText('10 20 +')).toBeInTheDocument()
    expect(screen.getByText('30')).toBeInTheDocument() // cached `{results: 30}
    expect(screen.getByText('inert')).toBeInTheDocument() // python: no dialect
  })
})
