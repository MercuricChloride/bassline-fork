import { describe, it, expect } from 'vitest'
import { print } from '../src/text/print.js'
import { read } from '../src/text/reader.js'
import {
  eq,
  withMark,
  bytes,
  nil,
  int,
  string,
  symbol,
  list,
  record,
  dict,
  set,
} from '../src/data.js'

const bs = (...n) => bytes(Uint8Array.of(...n))
const act = v => withMark(v, true)

describe('atom formatting', () => {
  it('formats each atom so it re-parses', () => {
    expect(print(nil())).toBe('nil')
    expect(print(int(42n))).toBe('42')
    expect(print(int(-7n))).toBe('-7')
    expect(print(string('hi'))).toBe('"hi"')
    expect(print(bytes(Uint8Array.of(0xde, 0xad)))).toBe('#[DEAD]')
    expect(print(bytes(new Uint8Array(0)))).toBe('#[]')
  })

  it('escapes strings (double-quoted)', () => {
    expect(print(string(''))).toBe('""')
    expect(print(string('say "hi"'))).toBe('"say \\"hi\\""')
    expect(print(string('a\nb\t'))).toBe('"a\nb\\t"') // newline literal, tab escaped
    expect(print(string("it's fine"))).toBe('"it\'s fine"') // a single quote is literal in a string
  })

  it('prints symbols bare only when they lex back unchanged', () => {
    expect(print(symbol('point'))).toBe('point')
    expect(print(symbol('a.b'))).toBe('a.b')
    expect(print(symbol('+'))).toBe('+')
    expect(print(symbol('a|b'))).toBe('a|b') // | is an ordinary symbol char now
    expect(print(symbol('a b'))).toBe("'a b'") // whitespace
    expect(print(symbol('a,b'))).toBe("'a,b'") // , reads as whitespace
    expect(print(symbol('a:b'))).toBe("'a:b'") // delimiter
    expect(print(symbol('a;b'))).toBe("'a;b'") // ; starts a comment now
    expect(print(symbol('->'))).toBe('->') // <> are ordinary symbol chars now
    expect(print(symbol('a(b'))).toBe("'a(b'") // ( is a record delimiter
    expect(print(symbol('a"b'))).toBe("'a\"b'") // contains the string delimiter
    expect(print(symbol('nil'))).toBe("'nil'") // the one reserved word
    expect(print(symbol('null'))).toBe('null') // NOT reserved (nil is)
    expect(print(symbol('true'))).toBe('true') // no longer reserved: a plain symbol
    expect(print(symbol('NaN'))).toBe('NaN') // ditto
    expect(print(symbol('1x'))).toBe("'1x'") // number-like start
    expect(print(symbol('-5'))).toBe("'-5'") // would lex as a number
    expect(print(symbol('+5'))).toBe('+5') // + is not a sign; lexes back as a symbol
  })

  it('quotes a symbol body on its own quote', () => {
    expect(print(symbol("it's"))).toBe("'it\\'s'")
  })

  it('prefixes actionable values with a backtick', () => {
    expect(print(act(symbol('x')))).toBe('`x')
    expect(print(act(int(1n)))).toBe('`1')
  })
})

describe('frame layout', () => {
  it('prints short frames inline', () => {
    expect(print(list([]))).toBe('[]')
    expect(print(dict([]))).toBe('{}')
    expect(print(set([]))).toBe('#{}')
    expect(print(record([symbol('point')]))).toBe('(point)')
    expect(print(list([int(1n), int(2n)]))).toBe('[1 2]')
    expect(print(set([int(1n), int(2n)]))).toBe('#{1 2}')
    expect(
      print(
        dict([
          [symbol('a'), int(1n)],
          [symbol('b'), int(2n)],
        ])
      )
    ).toBe('{a: 1 b: 2}')
    expect(print(record([symbol('point'), int(1n), int(2n)]))).toBe(
      '(point 1 2)'
    )
    expect(print(list([list([int(1n)])]))).toBe('[[1]]') // nested short stays inline
  })

  it('breaks a frame that exceeds the width', () => {
    const wide = list(Array.from({ length: 40 }, (_, i) => int(BigInt(i))))
    const out = print(wide)
    expect(out.startsWith('[\n')).toBe(true)
    expect(out.endsWith('\n]')).toBe(true)
    expect(out).toContain('\n  0\n') // first item on its own indented line
  })

  it('breaks the outer frame but keeps short inner frames inline', () => {
    const cells = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'].map((n, i) =>
      record([symbol('cell'), symbol(n), int(BigInt(i))])
    )
    const out = print(record([symbol('sheet'), ...cells]), 40)
    expect(out.startsWith('(sheet\n')).toBe(true)
    expect(out).toContain('\n  (cell A 0)\n') // inner cell inline, indented
    expect(out.endsWith('\n)')).toBe(true)
  })

  it('respects a custom width', () => {
    expect(print(list([int(1n), int(2n)]), 3)).toBe('[\n  1\n  2\n]')
  })
})

describe('round-trip: read(print(v)) eq v', () => {
  const samples = [
    nil(),
    int(0n),
    int(-255n),
    int(123456789012345678901234567890n),
    string(''),
    string('quotes \' and " and \\ and \n newline'),
    string('unicode π 😀'),
    symbol('bare'),
    symbol('needs quoting: <>'),
    symbol('a,b'), // , reads as whitespace — must re-read as one symbol
    symbol('a|b'), // | is an ordinary symbol char
    symbol('null'), // not reserved
    symbol('nil'), // reserved — quotes
    symbol('true'), // not reserved anymore — prints bare, re-reads as a symbol
    bs(),
    bs(0, 1, 254, 255),
    list([int(1n), string('two'), symbol('three')]),
    dict([
      [symbol('a'), int(1n)],
      [symbol('b'), int(2n)],
    ]),
    set([int(1n), int(2n), int(3n)]),
    record([symbol('point'), int(1n), int(2n)]),
    // nesting + actionable values (non-Data values still round-trip)
    list([dict([[symbol('k'), set([int(1n)])]]), record([symbol('tag')])]),
    act(symbol('x')),
    act(list([int(1n), int(2n)])),
    list([act(int(1n)), int(2n)]),
    dict([[symbol('a'), act(int(1n))]]),
    record([act(symbol('head')), int(1n)]),
  ]

  it.each(samples.map((v, i) => [i, v]))('round-trips sample %i', (_i, v) => {
    expect(eq(read(print(v))[0], v)).toBe(true)
  })
})
