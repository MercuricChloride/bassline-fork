import { describe, it, expect } from 'vitest'
import { read, readSpans, ReaderError } from '../src/text/reader.js'
import {
  encode,
  decode,
  eq,
  isActionable,
  withMark,
  int,
  string,
  symbol,
  nil,
  list,
  dict,
  set,
  record,
  bytes,
} from '../src/data.js'

/**
 * Parse a source expected to hold exactly one value, and return it.
 * @param src
 */
const val = src => {
  const vs = read(src)
  expect(vs).toHaveLength(1)
  return vs[0]
}

describe('documents', () => {
  it('parses zero or more whitespace-separated values into an array', () => {
    expect(read('')).toEqual([])
    const vs = read('42 "hi" foo')
    expect(vs).toHaveLength(3)
    expect(eq(vs[0], int(42n))).toBe(true)
    expect(eq(vs[1], string('hi'))).toBe(true)
    expect(eq(vs[2], symbol('foo'))).toBe(true)
  })
})

describe('atoms', () => {
  it('parses each atom kind', () => {
    expect(eq(val('nil'), nil())).toBe(true)
    expect(eq(val('-7'), int(-7n))).toBe(true)
    expect(eq(val('"hi"'), string('hi'))).toBe(true) // double quotes: a string
    expect(eq(val("'sym'"), symbol('sym'))).toBe(true) // single quotes: a symbol
    expect(eq(val('foo'), symbol('foo'))).toBe(true)
    expect(eq(val('#[DEAD]'), bytes(Uint8Array.of(0xde, 0xad)))).toBe(true)
  })

  it('distinguishes a quoted symbol from the reserved word', () => {
    expect(val("'nil'").kind).toBe('symbol')
    expect(val('nil').kind).toBe('nil')
  })

  it('reads former reserved words as plain symbols', () => {
    for (const w of ['true', 'false', 'NaN', 'Infinity', '-Infinity']) {
      expect(eq(val(w), symbol(w))).toBe(true)
    }
  })
})

describe('frames', () => {
  it('parses empty frames', () => {
    expect(eq(val('[]'), list([]))).toBe(true)
    expect(eq(val('{}'), dict([]))).toBe(true)
    expect(eq(val('#{}'), set([]))).toBe(true)
    expect(() => val('()')).toThrow('Record cannot be empty!')
  })

  it('parses a record', () => {
    expect(
      eq(val('(point 1 2)'), record([symbol('point'), int(1n), int(2n)]))
    ).toBe(true)
  })

  it('reads angle characters as bare symbols', () => {
    expect(eq(val('->'), symbol('->'))).toBe(true)
    expect(eq(val('<='), symbol('<='))).toBe(true)
    expect(eq(val('>='), symbol('>='))).toBe(true)
    expect(
      eq(val('(lt a b)'), record([symbol('lt'), symbol('a'), symbol('b')]))
    ).toBe(true)
  })

  it('parses a dictionary, splitting on the colon', () => {
    const want = dict([
      [symbol('a'), int(1n)],
      [symbol('b'), int(2n)],
    ])
    expect(eq(val('{a: 1 b: 2}'), want)).toBe(true)
    expect(eq(val('{a:1 b:2}'), want)).toBe(true)
  })

  it('parses nesting', () => {
    const v = val('[1 [2] {a: "x"}]')
    expect(v.kind).toBe('list')
    expect(
      eq(
        v,
        list([int(1n), list([int(2n)]), dict([[symbol('a'), string('x')]])])
      )
    ).toBe(true)
  })
})

describe('actionable', () => {
  it('parses an actionable value', () => {
    const v = val('`foo')
    expect(isActionable(v)).toBe(true)
    expect(eq(v, withMark(symbol('foo'), true))).toBe(true)
  })

  it('parses an actionable frame', () => {
    expect(eq(val('`[1 2]'), withMark(list([int(1n), int(2n)]), true))).toBe(
      true
    )
  })

  it('allows structurally nested actionables', () => {
    expect(
      eq(val('`[`a]'), withMark(list([withMark(symbol('a'), true)]), true))
    ).toBe(true)
  })

  it('accepts an actionable dict key (the Data firewall is gone)', () => {
    expect(eq(val('{`a: 1}'), dict([[symbol('a', true), int(1n)]]))).toBe(true)
  })
})

describe('comments', () => {
  it('skips a full-line comment', () => {
    expect(read('; nothing here')).toEqual([])
    expect(eq(val('; note\n42'), int(42n))).toBe(true)
  })

  it('skips a trailing comment', () => {
    expect(eq(val('42 ; the answer'), int(42n))).toBe(true)
  })

  it('skips comments inside frames', () => {
    expect(eq(val('[1 ; first\n 2]'), list([int(1n), int(2n)]))).toBe(true)
    expect(eq(val('{a: ; key a\n 1}'), dict([[symbol('a'), int(1n)]]))).toBe(
      true
    )
    expect(eq(val('(p ; head\n 1)'), record([symbol('p'), int(1n)]))).toBe(true)
  })

  it('a quoted symbol still holds a semicolon', () => {
    expect(eq(val("';'"), symbol(';'))).toBe(true)
  })

  it('a bare semicolon ends a symbol', () => {
    const vs = read('a;b')
    expect(vs).toHaveLength(1)
    expect(eq(vs[0], symbol('a'))).toBe(true)
  })

  it('ends a number at a semicolon', () => {
    expect(eq(val('42;x'), int(42n))).toBe(true)
  })

  it('spans start after leading comments', () => {
    const [s] = readSpans('; c\n 42')
    expect(s.start).toBe(5)
    expect(s.end).toBe(7)
  })
})

describe('errors', () => {
  it('rejects a record with no head', () => {
    expect(() => read('()')).toThrow()
  })

  it('rejects a stray closer', () => {
    expect(() => read(']')).toThrow()
    expect(() => read(')')).toThrow()
  })

  it('rejects an unterminated frame', () => {
    expect(() => read('[1 2')).toThrow()
    expect(() => read('{a: 1')).toThrow()
  })

  it('rejects a dictionary entry without a colon', () => {
    expect(() => read('{a 1}')).toThrow()
  })

  it('rejects a decimal literal', () => {
    expect(() => read('1.5')).toThrow('decimal')
    expect(() => read('-0.5')).toThrow('decimal')
  })

  it('carries pos/line/col on the ReaderError', () => {
    let err
    try {
      read('[1\n  2 )')
    } catch (e) {
      err = e
    }
    expect(err).toBeInstanceOf(ReaderError)
    expect(err.line).toBe(2)
    expect(err.col).toBe(5)
    expect(err.pos).toBe(7)
  })
})

describe('readSpans', () => {
  it('projects to the same values as read', () => {
    const src = '(entry "k" #{1 2 3}) [1 2] `foo'
    const spanned = readSpans(src)
    expect(spanned.map(s => s.value)).toEqual(read(src))
  })

  it('spans an atom by byte offsets, with no children', () => {
    const [s] = readSpans('  42 ')
    expect(s.start).toBe(2)
    expect(s.end).toBe(4)
    expect(s.children).toEqual([])
  })

  it('includes the actionable backtick in the span', () => {
    const [s] = readSpans('`foo')
    expect(s.value.actionable).toBe(true)
    expect(s.start).toBe(0)
    expect(s.end).toBe(4)
  })

  it('exposes list members as child spans', () => {
    const [s] = readSpans('[1 22]')
    expect(s.children.map(c => [c.start, c.end])).toEqual([
      [1, 2],
      [3, 5],
    ])
  })

  it('exposes the record head as the first child', () => {
    const [s] = readSpans('(a b)')
    expect(s.children).toHaveLength(2)
    expect(s.children[0].value.value).toBe('a')
    expect(s.children[0].start).toBe(1)
  })

  it('exposes dict keys and values as interleaved child spans', () => {
    const [s] = readSpans('{k: 1}')
    expect(s.children).toHaveLength(2)
    expect(s.children[0].value.value).toBe('k')
    expect([s.children[1].start, s.children[1].end]).toEqual([4, 5])
  })
})

describe('round-trip with canonical encoding', () => {
  it('parse then encode reproduces hand-built values', () => {
    const v = val('(entry "k" #{1 2 3})')
    const want = record([
      symbol('entry'),
      string('k'),
      set([int(1n), int(2n), int(3n)]),
    ])
    expect(eq(v, want)).toBe(true)
    expect(eq(decode(encode(v)), v)).toBe(true)
  })
})

describe('input validation', () => {
  it('rejects a non-string source at the boundary', () => {
    for (const bad of [42, null, undefined, [int(1n)]]) {
      expect(() => read(bad)).toThrow(TypeError)
    }
  })
})
