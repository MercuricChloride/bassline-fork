import { describe, it, expect } from 'vitest'
import { parse } from '../src/parser.js'
import * as D from '../src/data.js'

/** Parse a source expected to hold exactly one value, and return it. */
const val = (src) => {
  const vs = parse(src)
  expect(vs).toHaveLength(1)
  return vs[0]
}

describe('documents', () => {
  it('parses zero or more whitespace-separated values', () => {
    expect(parse('')).toEqual([])
    const vs = parse("42 'hi' foo")
    expect(vs).toHaveLength(3)
    expect(D.eq(vs[0], D.int(42n))).toBe(true)
    expect(D.eq(vs[1], D.str('hi'))).toBe(true)
    expect(D.eq(vs[2], D.sym('foo'))).toBe(true)
  })
})

describe('atoms', () => {
  it('parses each atom kind', () => {
    expect(D.eq(val('null'), D.nul())).toBe(true)
    expect(D.eq(val('true'), D.bool(true))).toBe(true)
    expect(D.eq(val('-7'), D.int(-7n))).toBe(true)
    expect(D.eq(val('1.5'), D.float(1.5))).toBe(true)
    expect(D.eq(val("'hi'"), D.str('hi'))).toBe(true)
    expect(D.eq(val('foo'), D.sym('foo'))).toBe(true)
    expect(D.eq(val('#[DEAD]'), D.bytes(Uint8Array.of(0xde, 0xad)))).toBe(true)
  })

  it('distinguishes a quoted reserved symbol from the reserved word', () => {
    expect(val('|null|')).toBeInstanceOf(D.BasslineSymbol)
    expect(val('null')).toBeInstanceOf(D.BasslineNull)
  })
})

describe('frames', () => {
  it('parses empty frames', () => {
    expect(D.eq(val('[]'), D.list([]))).toBe(true)
    expect(D.eq(val('{}'), D.dict([]))).toBe(true)
    expect(D.eq(val('#{}'), D.set([]))).toBe(true)
  })

  it('parses a record', () => {
    expect(D.eq(val('<point 1 2>'), D.record(D.sym('point'), [D.int(1n), D.int(2n)]))).toBe(true)
  })

  it('parses a dictionary, splitting on the colon', () => {
    const want = D.dict([[D.sym('a'), D.int(1n)], [D.sym('b'), D.int(2n)]])
    expect(D.eq(val('{a: 1 b: 2}'), want)).toBe(true)
    expect(D.eq(val('{a:1 b:2}'), want)).toBe(true)
  })

  it('parses nesting', () => {
    const v = val("[1 [2] {a: 'x'}]")
    expect(v).toBeInstanceOf(D.BasslineList)
    expect(D.eq(v, D.list([D.int(1n), D.list([D.int(2n)]), D.dict([[D.sym('a'), D.str('x')]])]))).toBe(
      true,
    )
  })
})

describe('the mark', () => {
  it('parses a marked value', () => {
    const v = val('`foo')
    expect(D.isMarked(v)).toBe(true)
    expect(D.eq(v, D.mark(D.sym('foo')))).toBe(true)
  })

  it('parses a marked frame', () => {
    expect(D.eq(val('`[1 2]'), D.mark(D.list([D.int(1n), D.int(2n)])))).toBe(true)
  })

  it('allows structurally nested marks', () => {
    expect(D.eq(val('`[`a]'), D.mark(D.list([D.mark(D.sym('a'))])))).toBe(true)
  })

  it('rejects two marks in a row', () => {
    expect(() => parse('``foo')).toThrow()
  })
})

describe('errors', () => {
  it('rejects a record with no head', () => {
    expect(() => parse('<>')).toThrow()
  })

  it('rejects a stray closer or reserved paren', () => {
    expect(() => parse(']')).toThrow()
    expect(() => parse('(')).toThrow()
  })

  it('rejects an unterminated frame', () => {
    expect(() => parse('[1 2')).toThrow()
    expect(() => parse('{a: 1')).toThrow()
  })

  it('rejects a dictionary entry without a colon', () => {
    expect(() => parse('{a 1}')).toThrow()
  })

  it('propagates duplicate-key and duplicate-member errors from the model', () => {
    expect(() => parse('{a: 1 a: 2}')).toThrow()
    expect(() => parse('#{1 1}')).toThrow()
  })

  it('propagates the marked-key error from the model', () => {
    expect(() => parse('{`a: 1}')).toThrow()
  })
})

describe('round-trip with canonical encoding', () => {
  it('parse then encode reproduces hand-built values', () => {
    const v = val("<entry 'k' #{1 2 3}>")
    const want = D.record(D.sym('entry'), [
      D.str('k'),
      D.set([D.int(1n), D.int(2n), D.int(3n)]),
    ])
    expect(D.eq(v, want)).toBe(true)
    expect(D.eq(D.decode(D.encode(v)), v)).toBe(true)
  })
})
