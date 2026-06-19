import { describe, it, expect } from 'vitest'
import { print } from '../src/text/print.js'
import { read } from '../src/text/reader.js'
import * as D from '../src/data.js'

const bs = (...n) => D.bytes(Uint8Array.of(...n))
const act = v => v.toActionable()

describe('atom formatting', () => {
  it('formats each atom so it re-parses', () => {
    expect(print(D.nil())).toBe('nil')
    expect(print(D.bool(true))).toBe('true')
    expect(print(D.int(42n))).toBe('42')
    expect(print(D.int(-7n))).toBe('-7')
    expect(print(D.str('hi'))).toBe('"hi"')
    expect(print(D.bytes(Uint8Array.of(0xde, 0xad)))).toBe('#[DEAD]')
    expect(print(D.bytes(new Uint8Array(0)))).toBe('#[]')
  })

  it('formats doubles as doubles, never integers', () => {
    expect(print(D.float(1))).toBe('1.0')
    expect(print(D.float(-5))).toBe('-5.0')
    expect(print(D.float(3.14))).toBe('3.14')
    expect(print(D.float(6.022e23))).toBe('6.022e+23')
    expect(print(D.float(-0))).toBe('-0.0')
    expect(print(D.float(NaN))).toBe('NaN')
    expect(print(D.float(Infinity))).toBe('Infinity')
    expect(print(D.float(-Infinity))).toBe('-Infinity')
  })

  it('escapes strings (double-quoted)', () => {
    expect(print(D.str(''))).toBe('""')
    expect(print(D.str('say "hi"'))).toBe('"say \\"hi\\""')
    expect(print(D.str('a\nb\t'))).toBe('"a\\nb\\t"')
    expect(print(D.str("it's fine"))).toBe('"it\'s fine"') // a single quote is literal in a string
  })

  it('prints symbols bare only when they lex back unchanged', () => {
    expect(print(D.sym('point'))).toBe('point')
    expect(print(D.sym('a.b'))).toBe('a.b')
    expect(print(D.sym('+'))).toBe('+')
    expect(print(D.sym('a|b'))).toBe('a|b') // | is an ordinary symbol char now
    expect(print(D.sym('a b'))).toBe("'a b'") // whitespace
    expect(print(D.sym('a:b'))).toBe("'a:b'") // delimiter
    expect(print(D.sym('->'))).toBe("'->'") // contains >
    expect(print(D.sym('a"b'))).toBe("'a\"b'") // contains the string delimiter
    expect(print(D.sym('nil'))).toBe("'nil'") // reserved word
    expect(print(D.sym('null'))).toBe('null') // NOT reserved (nil is)
    expect(print(D.sym('1x'))).toBe("'1x'") // number-like start
    expect(print(D.sym('-5'))).toBe("'-5'") // would lex as a number
  })

  it('quotes a symbol body on its own quote', () => {
    expect(print(D.sym("it's"))).toBe("'it\\'s'")
  })

  it('prefixes actionable values with a backtick', () => {
    expect(print(act(D.sym('x')))).toBe('`x')
    expect(print(act(D.int(1n)))).toBe('`1')
  })
})

describe('frame layout', () => {
  it('prints short frames inline', () => {
    expect(print(D.list([]))).toBe('[]')
    expect(print(D.dict([]))).toBe('{}')
    expect(print(D.set([]))).toBe('#{}')
    expect(print(D.record(D.sym('point')))).toBe('<point>')
    expect(print(D.list([D.int(1n), D.int(2n)]))).toBe('[1 2]')
    expect(print(D.set([D.int(1n), D.int(2n)]))).toBe('#{1 2}')
    expect(
      print(
        D.dict([
          [D.sym('a'), D.int(1n)],
          [D.sym('b'), D.int(2n)],
        ])
      )
    ).toBe('{a: 1 b: 2}')
    expect(print(D.record(D.sym('point'), D.int(1n), D.int(2n)))).toBe(
      '<point 1 2>'
    )
    expect(print(D.list([D.list([D.int(1n)])]))).toBe('[[1]]') // nested short stays inline
  })

  it('breaks a frame that exceeds the width', () => {
    const wide = D.list(Array.from({ length: 40 }, (_, i) => D.int(BigInt(i))))
    const out = print(wide)
    expect(out.startsWith('[\n')).toBe(true)
    expect(out.endsWith('\n]')).toBe(true)
    expect(out).toContain('\n  0\n') // first item on its own indented line
  })

  it('breaks the outer frame but keeps short inner frames inline', () => {
    const cells = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'].map((n, i) =>
      D.record(D.sym('cell'), D.sym(n), D.int(BigInt(i)))
    )
    const out = print(D.record(D.sym('sheet'), ...cells), 40)
    expect(out.startsWith('<sheet\n')).toBe(true)
    expect(out).toContain('\n  <cell A 0>\n') // inner cell inline, indented
    expect(out.endsWith('\n>')).toBe(true)
  })

  it('respects a custom width', () => {
    expect(print(D.list([D.int(1n), D.int(2n)]), 3)).toBe('[\n  1\n  2\n]')
  })
})

describe('round-trip: read(print(v)) eq v', () => {
  const samples = [
    D.nil(),
    D.bool(true),
    D.bool(false),
    D.int(0n),
    D.int(-255n),
    D.int(123456789012345678901234567890n),
    D.float(1),
    D.float(-0),
    D.float(NaN),
    D.float(Infinity),
    D.float(-Infinity),
    D.float(3.14159),
    D.str(''),
    D.str('quotes \' and " and \\ and \n newline'),
    D.str('unicode π 😀'),
    D.sym('bare'),
    D.sym('needs quoting: <>'),
    D.sym('a|b'), // | is an ordinary symbol char
    D.sym('null'), // not reserved
    D.sym('nil'), // reserved — quotes
    bs(),
    bs(0, 1, 254, 255),
    D.list([D.int(1n), D.str('two'), D.sym('three')]),
    D.dict([
      [D.sym('a'), D.int(1n)],
      [D.sym('b'), D.int(2n)],
    ]),
    D.set([D.int(1n), D.int(2n), D.int(3n)]),
    D.record(D.sym('point'), D.int(1n), D.int(2n)),
    // nesting + actionable values (non-Data values still round-trip)
    D.list([
      D.dict([[D.sym('k'), D.set([D.int(1n)])]]),
      D.record(D.sym('tag')),
    ]),
    act(D.sym('x')),
    act(D.list([D.int(1n), D.int(2n)])),
    D.list([act(D.int(1n)), D.int(2n)]),
    D.dict([[D.sym('a'), act(D.int(1n))]]),
    D.record(act(D.sym('head')), D.int(1n)),
  ]

  it.each(samples.map((v, i) => [i, v]))('round-trips sample %i', (_i, v) => {
    expect(D.eq(read(print(v))[0], v)).toBe(true)
  })
})
