import { screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { read } from '@bassline/core/text'
import report from '../../public/examples/report.blt?raw'
import recipe from '../../public/examples/recipe.blt?raw'
import untrusted from '../../public/examples/untrusted.blt?raw'
import { testRender } from '~/utils/test-render'
import { DocumentView } from '~/view/hooks'

const show = (src: string) => testRender(<DocumentView doc={read(src)[0]} />)

describe('showcase: report — computation carried in the document', () => {
  it('renders the source program and offers to run it (no cached result)', () => {
    show(report)
    expect(screen.getByText('120 90 75 + +')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /run/i })).toBeInTheDocument()
  })
})

describe('showcase: untrusted — custody without comprehension', () => {
  it('offers to run forth but holds python and sql inert', () => {
    show(untrusted)
    expect(screen.getByText('6 7 *')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /run/i })).toBeInTheDocument() // forth only
    expect(screen.getAllByText('inert')).toHaveLength(2) // python + sql
  })
})

describe('showcase: recipe — partial recognition / graceful degradation', () => {
  it('renders known heads richly and unknown heads via the labeled fallback', () => {
    show(recipe)
    expect(
      screen.getByRole('heading', { name: /pancakes/i })
    ).toBeInTheDocument()
    expect(screen.getByText('recipe')).toBeInTheDocument()
    expect(screen.getAllByText('ingredient').length).toBe(3)
    expect(screen.getAllByText('step').length).toBe(2)
    expect(screen.getByText(/whisk everything/i)).toBeInTheDocument()
  })
})
