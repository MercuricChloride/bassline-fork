import { describe, expect, it, vi } from 'vitest'
import { read } from '@bassline/core/text'
import { Affordances } from '../src/affordances'

const noop = () => {}

describe('Affordances', () => {
  it('offers and resolves concrete affordances', () => {
    const p = new Affordances()
    p.offer({ name: 'format', title: 'Format', run: noop })
    expect(p.get('format')?.title).toBe('Format')
    expect(p.list().map(a => a.name)).toEqual(['format'])
  })

  it('constructs affordances from a loaded document via kinds', () => {
    const p = new Affordances()
    p.kind('endpoint', d => {
      // The kind closes over the directive; the run reads it when invoked.
      void d
      return { name: 'deploy', title: 'Send via deploy', run: noop }
    })
    const handle = p.load(read('`<endpoint {name: "deploy" port: 9000}>'))
    expect(p.get('deploy')?.title).toBe('Send via deploy')

    // The load handle removes exactly what it added.
    handle.dispose()
    expect(p.get('deploy')).toBeUndefined()
  })

  it('ignores directives whose head names no known kind', () => {
    const p = new Affordances()
    const make = vi.fn()
    p.kind('endpoint', () => {
      make()
      return undefined
    })
    p.load(read('`<unknown {x: 1}>'))
    expect(make).not.toHaveBeenCalled()
    expect(p.list()).toHaveLength(0)
  })

  it('ignores content (non-actionable forms)', () => {
    const p = new Affordances()
    p.kind('endpoint', () => ({ name: 'deploy', title: 't', run: noop }))
    p.load(read('<endpoint {port: 9000}>'))
    expect(p.list()).toHaveLength(0)
  })

  it('resolve constructs an affordance from a directive without registering it', () => {
    const p = new Affordances()
    p.kind('endpoint', () => ({
      name: 'deploy',
      title: 'Send via deploy',
      run: noop,
    }))
    const [directive] = read('`<endpoint {name: "deploy" port: 9000}>')
    expect(p.resolve(directive)?.name).toBe('deploy')
    // resolve does not register: the command list stays empty.
    expect(p.list()).toHaveLength(0)
  })

  it('resolve returns undefined for an unknown head', () => {
    const p = new Affordances()
    const [directive] = read('`<unknown {x: 1}>')
    expect(p.resolve(directive)).toBeUndefined()
  })
})
