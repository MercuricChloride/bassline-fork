import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import {
  cmp,
  encode,
  pretty,
  print,
  readDocument,
  Reader,
  ReadError,
  ReadIncomplete,
  readValue,
  value,
  type Value,
} from '../src/index.ts'
import { randValue } from './random.ts'

const dir = new URL('../../../corpus/', import.meta.url)
const source = readFileSync(new URL('corpus.bl', dir), 'utf8')
const cases = readDocument(value, source) as Value<'record'>[]
const byHead = (head: string) =>
  cases.filter(c => c.head.kind === 'symbol' && c.head.payload === head)
const src = (c: Value<'record'>) => (c.items[1] as Value<'text'>).payload

const same = (a: Value, b: Value) => {
  expect(encode(a)).toEqual(encode(b))
  expect(cmp(a, b)).toBe(0)
}

/** What a Reader given the text in pieces of `n` characters lands. */
function inPieces(text: string, n: number): Value[] {
  const r = new Reader(value)
  const out: Value[] = []
  for (let i = 0; i < text.length; i += n) {
    r.add(text.slice(i, i + n))
    out.push(...r.values())
  }
  r.finish()
  out.push(...r.values())
  return out
}

function refusal(f: () => unknown) {
  try {
    f()
  } catch (e) {
    return e
  }
  throw new Error('not refused')
}

describe('corpus', () => {
  it('corpus.bl reads the same in pieces of any size', () => {
    for (const n of [1, 2, 3, 7, 64, 1000]) {
      const got = inPieces(source, n)
      expect(got.length).toBe(cases.length)
      got.forEach((v, i) => same(v, cases[i]!))
    }
  })
})

describe('corpus: reads', () => {
  for (const c of byHead('reads')) {
    it(JSON.stringify(src(c)), () =>
      same(readValue(value, src(c)), c.items[2]!)
    )
  }
})

describe('corpus: refuses', () => {
  for (const c of byHead('refuses')) {
    it(JSON.stringify(src(c)), () => {
      const e = refusal(() => readValue(value, src(c)))
      expect(e).toBeInstanceOf(ReadError)
      expect(e).not.toBeInstanceOf(ReadIncomplete)
    })
  }
})

describe('corpus: incomplete', () => {
  for (const c of byHead('incomplete')) {
    it(JSON.stringify(src(c)), () => {
      expect(() => readValue(value, src(c))).toThrow(ReadIncomplete)
      // a reader still being given text waits there instead
      const r = new Reader(value)
      r.add(src(c))
      expect([...r.values()]).toEqual([])
      r.finish()
      expect(() => [...r.values()]).toThrow(ReadIncomplete)
    })
  }
})

describe('corpus: document', () => {
  for (const c of byHead('document')) {
    it(JSON.stringify(src(c)), () => {
      const want = (c.items[2] as Value<'list'>).items
      const got = readDocument(value, src(c))
      expect(got.length).toBe(want.length)
      got.forEach((v, i) => same(v, want[i]!))
    })
  }
})

describe('print', () => {
  it('reads back as the value, flat and laid out', () => {
    for (let n = 0; n < 300; n++) {
      const v = randValue(3)
      same(readValue(value, print(v)), v)
      for (const w of [20, 80]) same(readValue(value, pretty(v, w)), v)
    }
  })

  it('prints the corpus values as the spec spells them', () => {
    expect(print(readValue(value, '{b: 2 a: 1}'))).toBe('{a: 1 b: 2}')
    expect(print(readValue(value, '!(f go! "x"!)'))).toBe('!(f go! "x"!)')
    expect(print(value.sym('nil'))).toBe("'nil'")
    expect(print(value.sym('-5'))).toBe("'-5'")
    expect(print(value.sym('->'))).toBe('->')
    expect(print(value.dict())).toBe('{:}')
    expect(print(value.set())).toBe('{}')
    expect(print(value.bytes(Uint8Array.of(0xde, 0x0a)))).toBe('0xde0a')
  })

  it('lays out within the width', () => {
    const v = readValue(
      value,
      '(config {name: "bassline" kinds: [nil number text symbol bytes list record dict set]})'
    )
    const out = pretty(v, 40)
    for (const line of out.split('\n'))
      expect(line.length).toBeLessThanOrEqual(40)
    expect(out.split('\n').length).toBeGreaterThan(1)
  })
})

describe('reading in pieces', () => {
  it('an atom touching the end waits, since the next piece may go on with it', () => {
    const r = new Reader(value)
    r.add('12')
    expect([...r.values()]).toEqual([])
    r.add('3 4')
    expect([...r.values()].map(print)).toEqual(['123'])
    r.finish()
    expect([...r.values()].map(print)).toEqual(['4'])
  })

  it('a mark at the end waits to see what it touches', () => {
    const r = new Reader(value)
    r.add('go')
    expect([...r.values()]).toEqual([])
    r.add('!')
    expect([...r.values()]).toEqual([])
    r.add('!(a)')
    // a frame closing at the end waits too: a mark behind it would be a fault
    expect([...r.values()].map(print)).toEqual(['go!'])
    r.finish()
    expect([...r.values()].map(print)).toEqual(['!(a)'])
  })

  it('refuses where the text says, and stays refused', () => {
    const r = new Reader(value)
    r.add('1 2\n[3 4) ')
    const got: Value[] = []
    const e = refusal(() => {
      for (const v of r.values()) got.push(v)
    }) as ReadError
    expect(got.map(print)).toEqual(['1', '2'])
    expect(e).toBeInstanceOf(ReadError)
    expect([e.line, e.col]).toEqual([2, 5])
    expect(() => [...r.values()]).toThrow(e)
    expect(() => r.add('5')).toThrow(e)
  })

  it('anything after a frame closing at the top lets it go', () => {
    const r = new Reader(value)
    r.add('[1 2 3 4 5 6 7 8]')
    expect([...r.values()]).toEqual([])
    r.add('x')
    expect([...r.values()].map(print)).toEqual(['[1 2 3 4 5 6 7 8]'])
  })

  it('a refusal inside a frame still open comes out by the time the text doubles', () => {
    const r = new Reader(value)
    r.add('[1 ')
    expect([...r.values()]).toEqual([])
    r.add('007 2 3 ')
    expect(() => [...r.values()]).toThrow(ReadError)
  })

  it('counts lines across pieces', () => {
    const r = new Reader(value)
    r.add('a\nb\n')
    expect([...r.values()].length).toBe(2)
    r.add('c ]')
    const e = refusal(() => [...r.values()]) as ReadError
    expect([e.line, e.col]).toEqual([3, 3])
  })

  it('a comment is whitespace, even unended', () => {
    const r = new Reader(value)
    r.add('1 ; one')
    r.finish()
    expect([...r.values()].map(print)).toEqual(['1'])
    expect(r.pending).toBe(false)
  })

  it('refuses nesting past the depth limit, as text and not by the call stack', () => {
    const deep = (n: number) => '['.repeat(n) + ']'.repeat(n)
    expect(readValue(value, deep(9), { maxDepth: 9 }).kind).toBe('list')
    expect(() => readValue(value, deep(9), { maxDepth: 8 })).toThrow(ReadError)
    const e = refusal(() => readValue(value, deep(100_000)))
    expect(e).toBeInstanceOf(ReadError)
    expect(e).not.toBeInstanceOf(ReadIncomplete)
    const r = new Reader(value, { maxDepth: 3 })
    r.add('[[[[')
    expect(() => [...r.values()]).toThrow(ReadError)
  })

  it('refuses a lone surrogate', () => {
    expect(() => readValue(value, '"\uD800"')).toThrow(ReadError)
    expect(() => readValue(value, 'a\uDC00')).toThrow(ReadError)
  })
})

describe('the factory is what builds', () => {
  it('is handed the members as written, and puts them in order', () => {
    const seen: string[] = []
    const spy = {
      ...value,
      set: (items: Iterable<Value> = [], mark = false) => {
        const xs = [...items]
        seen.push(xs.map(print).join(' '))
        return value.set(xs, mark)
      },
    }
    expect(print(readValue(spy, '{c b {z y} a}'))).toBe('{a b c {y z}}')
    expect(seen).toEqual(['z y', 'c b {y z} a'])
  })
})
