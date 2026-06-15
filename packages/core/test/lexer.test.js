import { describe, it, expect } from 'vitest'
import { lex, T } from '../src/text/lexer.js'

const types = src => lex(src).map(t => t.type)
const one = src => {
  const ts = lex(src)
  expect(ts).toHaveLength(1)
  return ts[0]
}

describe('structural tokens', () => {
  it('tokenizes a record', () => {
    expect(types('<point 1 2>')).toEqual([
      T.LANGLE,
      T.SYMBOL,
      T.INTEGER,
      T.INTEGER,
      T.RANGLE,
    ])
  })

  it('tokenizes a set open and a dict', () => {
    expect(types('#{}')).toEqual([T.SETOPEN, T.RBRACE])
    expect(types('{a: 1}')).toEqual([
      T.LBRACE,
      T.SYMBOL,
      T.COLON,
      T.INTEGER,
      T.RBRACE,
    ])
  })

  it('reserves parens', () => {
    expect(types('()')).toEqual([T.LPAREN, T.RPAREN])
  })

  it('emits one ACTION per backtick (parser rejects doubles)', () => {
    expect(types('`foo')).toEqual([T.ACTION, T.SYMBOL])
    expect(types('``foo')).toEqual([T.ACTION, T.ACTION, T.SYMBOL])
  })
})

describe('numbers', () => {
  it('distinguishes integers from doubles', () => {
    expect(one('42')).toMatchObject({ type: T.INTEGER, value: 42n })
    expect(one('-7')).toMatchObject({ type: T.INTEGER, value: -7n })
    expect(one('1.0')).toMatchObject({ type: T.DOUBLE, value: 1.0 })
    expect(one('6.022e23')).toMatchObject({ type: T.DOUBLE, value: 6.022e23 })
    expect(one('-0.0')).toMatchObject({ type: T.DOUBLE })
    expect(Object.is(one('-0.0').value, -0)).toBe(true)
  })

  it('accepts a redundant leading +', () => {
    expect(one('+5')).toMatchObject({ type: T.INTEGER, value: 5n })
  })

  it('rejects a number butting a symbol character', () => {
    // > is a delimiter so 1>2 is three tokens; these butt a non-delimiter.
    for (const bad of ['1px', '1!', '1-2', '1.']) {
      expect(() => lex(bad), bad).toThrow()
    }
  })
})

describe('reserved spellings', () => {
  it('reclassifies bare words', () => {
    expect(one('nil')).toMatchObject({ type: T.NIL })
    expect(one('true')).toMatchObject({ type: T.BOOL, value: true })
    expect(one('false')).toMatchObject({ type: T.BOOL, value: false })
    expect(Number.isNaN(one('NaN').value)).toBe(true)
    expect(one('Infinity')).toMatchObject({ type: T.DOUBLE, value: Infinity })
    expect(one('-Infinity')).toMatchObject({ type: T.DOUBLE, value: -Infinity })
  })

  it('does not reclassify near-misses or quoted symbols', () => {
    expect(one('nilish')).toMatchObject({ type: T.SYMBOL, value: 'nilish' })
    expect(one("'nil'")).toMatchObject({ type: T.SYMBOL, value: 'nil' })
  })
})

describe('symbols', () => {
  it('treats most punctuation as ordinary symbol characters', () => {
    expect(one(';')).toMatchObject({ type: T.SYMBOL, value: ';' })
    expect(one('+')).toMatchObject({ type: T.SYMBOL, value: '+' })
    expect(one('a.b')).toMatchObject({ type: T.SYMBOL, value: 'a.b' })
    expect(one('a|b')).toMatchObject({ type: T.SYMBOL, value: 'a|b' }) // | is ordinary now
  })

  it('treats commas as whitespace', () => {
    expect(types('a,b')).toEqual([T.SYMBOL, T.SYMBOL])
  })

  it('stops bare symbols at angle-bracket delimiters (so `->`, `<=` need quoting)', () => {
    expect(types('a>b')).toEqual([T.SYMBOL, T.RANGLE, T.SYMBOL])
    expect(one("'->'")).toMatchObject({ type: T.SYMBOL, value: '->' })
  })

  it('splits on the colon token', () => {
    expect(types('foo:bar')).toEqual([T.SYMBOL, T.COLON, T.SYMBOL])
    expect(types('foo: bar')).toEqual([T.SYMBOL, T.COLON, T.SYMBOL])
    expect(lex('foo:bar').map(t => t.value)).toEqual(['foo', undefined, 'bar'])
  })

  it('reads quoted symbols verbatim', () => {
    expect(one("'has space'")).toMatchObject({
      type: T.SYMBOL,
      value: 'has space',
    })
    expect(one("'a:b'")).toMatchObject({ type: T.SYMBOL, value: 'a:b' })
  })
})

describe('strings', () => {
  it('uses double quotes and reads escapes', () => {
    expect(one('"a\\nb"')).toMatchObject({ type: T.STRING, value: 'a\nb' })
    expect(one('"say \\"hi\\""')).toMatchObject({
      type: T.STRING,
      value: 'say "hi"',
    })
    expect(one('""')).toMatchObject({ type: T.STRING, value: '' })
  })

  it('rejects an unknown escape', () => {
    expect(() => lex('"a\\ub"')).toThrow() // \u is not an escape
    expect(() => lex("'a\\xb'")).toThrow() // \x is not an escape
  })

  it('rejects an unterminated string or symbol', () => {
    expect(() => lex('"abc')).toThrow()
    expect(() => lex("'abc")).toThrow()
  })
})

describe('bytestrings', () => {
  it('reads hex pairs ignoring inner whitespace', () => {
    expect(one('#[DEAD]').value).toEqual(Uint8Array.of(0xde, 0xad))
    expect(one('#[DE AD BE EF]').value).toEqual(
      Uint8Array.of(0xde, 0xad, 0xbe, 0xef)
    )
    expect(one('#[]').value).toEqual(new Uint8Array(0))
  })

  it('rejects odd hex, bad hex, unterminated, and a bare #', () => {
    expect(() => lex('#[ABC]')).toThrow()
    expect(() => lex('#[GG]')).toThrow()
    expect(() => lex('#[DE')).toThrow()
    expect(() => lex('#x')).toThrow()
  })
})

describe('whitespace', () => {
  it('is insignificant and yields no tokens on its own', () => {
    expect(lex('   \n\t ')).toEqual([])
    expect(lex('')).toEqual([])
  })
})

describe('input validation', () => {
  it('rejects a non-string source at the boundary', () => {
    for (const bad of [42, null, undefined, ['a'], { length: 1 }]) {
      expect(() => lex(bad)).toThrow(TypeError)
    }
  })
})
