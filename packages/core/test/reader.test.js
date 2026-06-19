import { describe, it, expect } from 'vitest'
import { read } from '../src/text/reader.js'
import * as D from '../src/data.js'

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
    expect(D.eq(vs[0], D.int(42n))).toBe(true)
    expect(D.eq(vs[1], D.str('hi'))).toBe(true)
    expect(D.eq(vs[2], D.sym('foo'))).toBe(true)
  })
})

describe('atoms', () => {
  it('parses each atom kind', () => {
    expect(D.eq(val('nil'), D.nil())).toBe(true)
    expect(D.eq(val('true'), D.bool(true))).toBe(true)
    expect(D.eq(val('-7'), D.int(-7n))).toBe(true)
    expect(D.eq(val('1.5'), D.float(1.5))).toBe(true)
    expect(D.eq(val('"hi"'), D.str('hi'))).toBe(true) // double quotes: a string
    expect(D.eq(val("'sym'"), D.sym('sym'))).toBe(true) // single quotes: a symbol
    expect(D.eq(val('foo'), D.sym('foo'))).toBe(true)
    expect(D.eq(val('#[DEAD]'), D.bytes(Uint8Array.of(0xde, 0xad)))).toBe(true)
  })

  it('distinguishes a quoted symbol from the reserved word', () => {
    expect(val("'nil'")).toBeInstanceOf(D.BasslineSymbol)
    expect(val('nil')).toBeInstanceOf(D.BasslineNil)
  })
})

describe('frames', () => {
  it('parses empty frames', () => {
    expect(D.eq(val('[]'), D.list([]))).toBe(true)
    expect(D.eq(val('{}'), D.dict([]))).toBe(true)
    expect(D.eq(val('#{}'), D.set([]))).toBe(true)
    expect(() => val('<>')).toThrow('Record cannot be empty!')
  })

  it('parses a record', () => {
    expect(
      D.eq(val('<point 1 2>'), D.record(D.sym('point'), D.int(1n), D.int(2n)))
    ).toBe(true)
  })

  it('parses a dictionary, splitting on the colon', () => {
    const want = D.dict([
      [D.sym('a'), D.int(1n)],
      [D.sym('b'), D.int(2n)],
    ])
    expect(D.eq(val('{a: 1 b: 2}'), want)).toBe(true)
    expect(D.eq(val('{a:1 b:2}'), want)).toBe(true)
  })

  it('parses nesting', () => {
    const v = val('[1 [2] {a: "x"}]')
    expect(v).toBeInstanceOf(D.BasslineList)
    expect(
      D.eq(
        v,
        D.list([
          D.int(1n),
          D.list([D.int(2n)]),
          D.dict([[D.sym('a'), D.str('x')]]),
        ])
      )
    ).toBe(true)
  })
})

describe('actionable', () => {
  it('parses an actionable value', () => {
    const v = val('`foo')
    expect(D.isActionable(v)).toBe(true)
    expect(D.eq(v, D.sym('foo').toActionable())).toBe(true)
  })

  it('parses an actionable frame', () => {
    expect(
      D.eq(val('`[1 2]'), D.list([D.int(1n), D.int(2n)]).toActionable())
    ).toBe(true)
  })

  it('allows structurally nested actionables', () => {
    expect(
      D.eq(val('`[`a]'), D.list([D.sym('a').toActionable()]).toActionable())
    ).toBe(true)
  })

  it('accepts an actionable dict key (the Data firewall is gone)', () => {
    expect(
      D.eq(val('{`a: 1}'), D.dict([[D.sym('a').toActionable(), D.int(1n)]]))
    ).toBe(true)
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
    const want = D.record(
      D.sym('entry'),
      D.str('k'),
      D.set([D.int(1n), D.int(2n), D.int(3n)])
    )
    expect(D.eq(v, want)).toBe(true)
    expect(D.eq(D.decode(D.encode(v)), v)).toBe(true)
  })
})

describe('input validation', () => {
  it('rejects a non-string source at the boundary', () => {
    for (const bad of [42, null, undefined, [D.int(1n)]]) {
      expect(() => read(bad)).toThrow(TypeError)
    }
  })
})
