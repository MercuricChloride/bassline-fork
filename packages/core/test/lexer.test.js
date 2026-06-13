import { describe, it, expect } from 'vitest'
import { lex, T } from '../src/lexer.js'

const types = (src) => lex(src).map((t) => t.type)
const one = (src) => {
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
    expect(types('{a: 1}')).toEqual([T.LBRACE, T.SYMBOL, T.COLON, T.INTEGER, T.RBRACE])
  })

  it('reserves parens', () => {
    expect(types('()')).toEqual([T.LPAREN, T.RPAREN])
  })

  it('emits one mark per backtick (parser rejects doubles)', () => {
    expect(types('`foo')).toEqual([T.MARK, T.SYMBOL])
    expect(types('``foo')).toEqual([T.MARK, T.MARK, T.SYMBOL])
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
    for (const bad of ['1px', '1,2', '1.', '1-2']) {
      expect(() => lex(bad), bad).toThrow()
    }
  })
})

describe('reserved spellings', () => {
  it('reclassifies bare words', () => {
    expect(one('null')).toMatchObject({ type: T.NULL })
    expect(one('true')).toMatchObject({ type: T.BOOL, value: true })
    expect(one('false')).toMatchObject({ type: T.BOOL, value: false })
    expect(Number.isNaN(one('NaN').value)).toBe(true)
    expect(one('Infinity')).toMatchObject({ type: T.DOUBLE, value: Infinity })
    expect(one('-Infinity')).toMatchObject({ type: T.DOUBLE, value: -Infinity })
  })

  it('does not reclassify near-misses or quoted symbols', () => {
    expect(one('nullish')).toMatchObject({ type: T.SYMBOL, value: 'nullish' })
    expect(one('|null|')).toMatchObject({ type: T.SYMBOL, value: 'null' })
  })
})

describe('symbols', () => {
  it('treats commas and semicolons as symbol characters', () => {
    expect(one(',')).toMatchObject({ type: T.SYMBOL, value: ',' })
    expect(one(';')).toMatchObject({ type: T.SYMBOL, value: ';' })
    expect(one('a,b')).toMatchObject({ type: T.SYMBOL, value: 'a,b' })
    expect(one('+')).toMatchObject({ type: T.SYMBOL, value: '+' })
    expect(one('a.b')).toMatchObject({ type: T.SYMBOL, value: 'a.b' })
  })

  it('stops bare symbols at angle-bracket delimiters (so `->`, `<=` need quoting)', () => {
    expect(types('a>b')).toEqual([T.SYMBOL, T.RANGLE, T.SYMBOL])
    expect(one('|->|')).toMatchObject({ type: T.SYMBOL, value: '->' })
  })

  it('splits on the colon token', () => {
    expect(types('foo:bar')).toEqual([T.SYMBOL, T.COLON, T.SYMBOL])
    expect(types('foo: bar')).toEqual([T.SYMBOL, T.COLON, T.SYMBOL])
    expect(lex('foo:bar').map((t) => t.value)).toEqual(['foo', undefined, 'bar'])
  })

  it('reads quoted symbols verbatim', () => {
    expect(one('|has space|')).toMatchObject({ type: T.SYMBOL, value: 'has space' })
    expect(one('|a:b|')).toMatchObject({ type: T.SYMBOL, value: 'a:b' })
  })
})

describe('strings', () => {
  it('reads escapes', () => {
    expect(one("'a\\nb'")).toMatchObject({ type: T.STRING, value: 'a\nb' })
    expect(one("'it\\'s'")).toMatchObject({ type: T.STRING, value: "it's" })
    expect(one("''")).toMatchObject({ type: T.STRING, value: '' })
  })

  it('reads unicode escapes', () => {
    expect(one("'\\u{1F600}'")).toMatchObject({ type: T.STRING, value: '\u{1F600}' })
  })

  it('rejects an invalid code point', () => {
    expect(() => lex("'\\u{D800}'")).toThrow()
    expect(() => lex("'\\u{110000}'")).toThrow()
  })

  it('rejects an unterminated string', () => {
    expect(() => lex("'abc")).toThrow()
    expect(() => lex('|abc')).toThrow()
  })
})

describe('bytestrings', () => {
  it('reads hex pairs ignoring inner whitespace', () => {
    expect(one('#[DEAD]').value).toEqual(Uint8Array.of(0xde, 0xad))
    expect(one('#[DE AD BE EF]').value).toEqual(Uint8Array.of(0xde, 0xad, 0xbe, 0xef))
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
