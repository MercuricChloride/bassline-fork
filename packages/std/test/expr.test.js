import { describe, expect, it } from 'vitest'
import {
  Binding,
  RuntimeNode,
  bindNode,
  createSeedContext,
  fromArray,
  node,
  nodep,
  projectValue,
} from '../src/expr/evaluator.js'

function sampleDocument() {
  return node('document', {}, [
    node('context', {}, [
      node('define', { tag: 'note' }, [
        node('section', {}, [node('children')]),
      ]),
      node('note', { title: 'Local note' }, [
        node('text', { value: 'Inside the contextual definition.' }),
      ]),
    ]),
    node('note', { title: 'Outside note' }),
  ])
}

describe('node form', () => {
  it('recognizes canonical object nodes only', () => {
    const canonical = node('text', { value: 'hello' })

    expect(nodep(canonical)).toBe(true)
    expect(nodep(['text', { value: 'hello' }])).toBe(false)
    expect(nodep({ tag: 'text', attrs: [], children: [] })).toBe(false)
    expect(nodep({ tag: 'text', attrs: {}, children: [['text', {}]] })).toBe(
      false
    )
  })

  it('converts array authoring sugar through fromArray', () => {
    expect(
      fromArray([
        'section',
        { title: 'Hello' },
        ['text', { value: 'Nested text' }],
      ])
    ).toEqual(
      node('section', { title: 'Hello' }, [
        node('text', { value: 'Nested text' }),
      ])
    )
  })

  it('rejects malformed canonical construction', () => {
    expect(() => node(123)).toThrow('tag must be a string')
    expect(() => node('text', [])).toThrow('attrs must be an object')
    expect(() => node('text', {}, ['not a node'])).toThrow(
      'children must be canonical nodes'
    )
  })
})

describe('contextual binding', () => {
  it('leaves unknown tags inert', async () => {
    const seed = createSeedContext()
    const unknown = node('note', { title: 'Outside note' })

    const result = await bindNode(seed, unknown)

    expect(result.ctx).toBe(seed)
    expect(result.value).toEqual(unknown)
  })

  it('localizes bindings inside a context node', async () => {
    const seed = createSeedContext()

    const { value: runtime } = await bindNode(seed, sampleDocument())

    expect(runtime).toBeInstanceOf(RuntimeNode)
    expect(runtime.binding).toBe(seed.lookup('document'))
    expect(seed.lookup('note')).toBeUndefined()

    const contextual = runtime.children[0]
    const outsideNote = runtime.children[1]

    expect(contextual.binding).toBe(seed.lookup('context'))
    expect(contextual.context.lookup('note')).toBeInstanceOf(Binding)
    expect(contextual.children).toHaveLength(1)
    expect(contextual.children[0].binding).toBe(seed.lookup('section'))
    expect(outsideNote).toEqual(node('note', { title: 'Outside note' }))
  })

  it('projects context recipes for explainable local bindings', async () => {
    const seed = createSeedContext()

    const { value: runtime } = await bindNode(seed, sampleDocument())
    const contextual = runtime.children[0]

    expect(contextual.context.project()).toEqual(
      node('context', {}, [
        node('define', { tag: 'note' }, [
          node('section', {}, [node('children')]),
        ]),
      ])
    )
  })

  it('projects bound runtime to lower nodes that can be rebound', async () => {
    const seed = createSeedContext()

    const { value: runtime } = await bindNode(seed, sampleDocument())
    const projected = projectValue(seed, runtime)

    expect(projected).toEqual(
      node('document', {}, [
        node('context', {}, [
          node('section', { title: 'Local note' }, [
            node('text', { value: 'Inside the contextual definition.' }),
          ]),
        ]),
        node('note', { title: 'Outside note' }),
      ])
    )

    const fresh = createSeedContext()
    const { value: rebound } = await bindNode(fresh, projected)

    expect(rebound.binding).toBe(fresh.lookup('document'))
    expect(rebound.children[0].children[0].binding).toBe(
      fresh.lookup('section')
    )
    expect(rebound.children[1]).toEqual(node('note', { title: 'Outside note' }))
  })

  it('lets definitions synthesize multiple lower children around use-site children', async () => {
    const seed = createSeedContext()
    const source = node('context', {}, [
      node('define', { tag: 'callout' }, [
        node('section', { tone: 'info' }, [
          node('text', { value: 'Note:' }),
          node('children'),
        ]),
      ]),
      node('callout', { title: 'Heads up' }, [
        node('text', { value: 'Templates can wrap their children.' }),
      ]),
    ])

    const { value: runtime } = await bindNode(seed, source)
    const callout = runtime.children[0]

    expect(callout.binding).toBe(seed.lookup('section'))
    expect(callout.attrs).toEqual({ title: 'Heads up', tone: 'info' })
    expect(callout.children.map(child => child.attrs.value)).toEqual([
      'Note:',
      'Templates can wrap their children.',
    ])
  })
})
