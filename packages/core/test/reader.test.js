import { describe, it, expect } from 'vitest'
import { read } from '../src/text/reader.js'
import {
  encode,
  decode,
  fresh,
  eq,
  isActionable,
  BasslineSymbol,
  BasslineNil,
  BasslineList,
} from '../src/data.js'

const {
  int,
  string,
  symbol,
  nil,
  bool,
  float,
  list,
  dict,
  set,
  record,
  bytes,
} = fresh

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
    expect(eq(val('true'), bool(true))).toBe(true)
    expect(eq(val('-7'), int(-7n))).toBe(true)
    expect(eq(val('1.5'), float(1.5))).toBe(true)
    expect(eq(val('"hi"'), string('hi'))).toBe(true) // double quotes: a string
    expect(eq(val("'sym'"), symbol('sym'))).toBe(true) // single quotes: a symbol
    expect(eq(val('foo'), symbol('foo'))).toBe(true)
    expect(eq(val('#[DEAD]'), bytes(Uint8Array.of(0xde, 0xad)))).toBe(true)
  })

  it('distinguishes a quoted symbol from the reserved word', () => {
    expect(val("'nil'")).toBeInstanceOf(BasslineSymbol)
    expect(val('nil')).toBeInstanceOf(BasslineNil)
  })
})

describe('frames', () => {
  it('parses empty frames', () => {
    expect(eq(val('[]'), list([]))).toBe(true)
    expect(eq(val('{}'), dict([]))).toBe(true)
    expect(eq(val('#{}'), set([]))).toBe(true)
    expect(() => val('<>')).toThrow('Record cannot be empty!')
  })

  it('parses a record', () => {
    expect(
      eq(val('<point 1 2>'), record([symbol('point'), int(1n), int(2n)]))
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
    expect(v).toBeInstanceOf(BasslineList)
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
    expect(eq(v, symbol('foo').copy(true))).toBe(true)
  })

  it('parses an actionable frame', () => {
    expect(eq(val('`[1 2]'), list([int(1n), int(2n)]).copy(true))).toBe(true)
  })

  it('allows structurally nested actionables', () => {
    expect(eq(val('`[`a]'), list([symbol('a').copy(true)]).copy(true))).toBe(
      true
    )
  })

  it('accepts an actionable dict key (the Data firewall is gone)', () => {
    expect(eq(val('{`a: 1}'), dict([[symbol('a', true), int(1n)]]))).toBe(true)
  })
})

describe('errors', () => {
  it('rejects a record with no head', () => {
    expect(() => read('<>')).toThrow()
  })

  it('rejects a stray closer or reserved paren', () => {
    expect(() => read(']')).toThrow()
    expect(() => read('(')).toThrow()
  })

  it('rejects an unterminated frame', () => {
    expect(() => read('[1 2')).toThrow()
    expect(() => read('{a: 1')).toThrow()
  })

  it('rejects a dictionary entry without a colon', () => {
    expect(() => read('{a 1}')).toThrow()
  })
})

describe('round-trip with canonical encoding', () => {
  it('parse then encode reproduces hand-built values', () => {
    const v = val('<entry "k" #{1 2 3}>')
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
