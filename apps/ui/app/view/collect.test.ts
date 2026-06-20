import { describe, expect, it } from 'vitest'
import type { Value } from '@bassline/core/data'
import { dict, record, str, sym } from '@bassline/core/data'
import { kind } from '@bassline/core/match'
import { read } from '@bassline/core/text'
// eslint-disable-next-line import/no-unresolved
import docSource from '../../public/document.blt?raw'
import { asString, collect, firstKey } from './collect'
import { at, headed, sk } from './match'

const doc = read(docSource)[0]

/** depth-first find first record with head symbol `name`. */
function find(v: Value, name: string): Value | undefined {
  if (headed(name)(v)) return v
  if (kind.record(v)) {
    for (const f of v.fields) {
      const hit = find(f, name)
      if (hit) return hit
    }
  }
  if (kind.list(v)) {
    for (const f of v.value) {
      const hit = find(f, name)
      if (hit) return hit
    }
  }
  return undefined
}

describe('collect — node gathers its own directives', () => {
  it("splits the block's children into two directives + one content string", () => {
    const block = find(doc, 'block')!
    expect(block).toBeDefined()
    const { directives, content } = collect(block)

    // `{language ...}  "10 20 +"  `{results ...}
    expect(directives).toHaveLength(2)
    expect(directives.every(d => kind.dict(d) && d.actionable)).toBe(true)

    expect(content).toHaveLength(1)
    expect(asString(content[0])).toBe('10 20 +')
  })

  it('does NOT merge directives — they remain standalone messages', () => {
    const block = find(doc, 'block')!
    const { directives } = collect(block)
    // language lives in the first directive, results in the second; collect
    // never combines them.
    expect(at(sk('language'))(directives[0])).toBeDefined()
    expect(at(sk('language'))(directives[1])).toBeUndefined()
    expect(at(sk('results'))(directives[1])).toBeDefined()
    expect(at(sk('results'))(directives[0])).toBeUndefined()
  })

  it('a node may fold directives itself (firstOf)', () => {
    const block = find(doc, 'block')!
    const { directives } = collect(block)
    expect(asString(firstKey(directives, 'language'))).toBe('forth')
  })

  it('link collects its href directive, content is the label', () => {
    const link = find(doc, 'link')!
    const { directives, content } = collect(link)
    expect(asString(at(sk('href'))(directives[0]))).toBe('https://example.com')
    expect(asString(content[0])).toBe('example')
  })

  it('an inert dict stays in content (data, not a directive)', () => {
    const node = record(sym('x'), dict([[sym('a'), str('b')]]))
    const { directives, content } = collect(node)
    expect(directives).toHaveLength(0)
    expect(content).toHaveLength(1)
    expect(kind.dict(content[0])).toBe(true)
  })
})
