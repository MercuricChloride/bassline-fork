import { fireEvent, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { read } from '@bassline/core/text'
import { record, str, sym } from '@bassline/core/data'
import { kind } from '@bassline/core/match'
import bindingsDoc from '../../public/examples/bindings.blt?raw'
import { testRender } from '~/utils/test-render'
import { keyOf, ref, resolve, seed } from '~/view/bindings'
import { DocumentView } from '~/view/hooks'
import { headed } from '~/view/match'

describe('bindings store (pure)', () => {
  const doc = read(bindingsDoc)[0]

  it('seeds custom bindings from def-custom, anywhere in the document', () => {
    const store = seed(doc)
    const customs = [...store.values()]
      .filter(b => b.custom)
      .map(b => (kind.symbol(b.sym) ? b.sym.value : ''))
      .sort()
    expect(customs).toEqual(['greeting', 'mood', 'pick'])
  })

  it('a marked symbol dereferences; an unbound one is an error', () => {
    const store = seed(doc)
    const got = resolve(ref('greeting'), store)
    expect(kind.string(got) && got.value).toBe('Hello')
    const miss = resolve(ref('nope'), store)
    expect(miss.kind === 'record').toBe(true) // <error unbound nope>
  })

  it('def name (inert) and reference (marked) collide on the same key', () => {
    expect(keyOf(sym('greeting'))).toBe(keyOf(ref('greeting')))
  })

  it('a `set name value` message is a record headed `set`', () => {
    const setMsg = record(sym('set'), sym('greeting'), str('Yo'))
    expect(headed('set')(setMsg)).toBe(true)
  })
})

describe('bindings (live, reactive)', () => {
  const show = () => testRender(<DocumentView doc={read(bindingsDoc)[0]} />)

  it('enumerates custom bindings into a generated panel', () => {
    show()
    expect(screen.getByDisplayValue('Hello')).toBeInTheDocument() // greeting
    expect(screen.getByDisplayValue('excited')).toBeInTheDocument() // mood
  })

  it('a button `set` updates the binding and every reference re-renders', () => {
    const { container } = show()
    expect(container.textContent).toContain('Greeting is now: Hello')
    fireEvent.click(screen.getByRole('button', { name: /^hi$/i }))
    expect(container.textContent).toContain('Greeting is now: Hi')
    expect(screen.getByDisplayValue('Hi')).toBeInTheDocument() // the panel reflects it too
  })

  it('editing the generated field updates the reference', () => {
    const { container } = show()
    fireEvent.change(screen.getByDisplayValue('Hello'), {
      target: { value: 'Howdy' },
    })
    expect(container.textContent).toContain('Greeting is now: Howdy')
  })
})
