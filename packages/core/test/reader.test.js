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

const bs = (...n) => bytes(Uint8Array.of(...n))
const act = v => withMark(v, true)

describe('documents', () => {
  it('parses zero or more whitespace-separated values into an array', () => {
    expect(read('')).toEqual([])
    const vs = read('42 "hi" foo')
    expect(vs).toHaveLength(3)
    expect(eq(vs[0], int(42n))).toBe(true)
    expect(eq(vs[1], string('hi'))).toBe(true)
    expect(eq(vs[2], symbol('foo'))).toBe(true)
  })

  it('a comma is an ordinary symbol character', () => {
    expect(eq(val('[a, b]'), list([symbol('a,'), symbol('b')]))).toBe(true)
    expect(() => read('[1, 2]')).toThrow(ReaderError) // '1,' is no number
  })
})

describe('atoms', () => {
  it('nil is reserved, quotable, markable', () => {
    expect(eq(val('nil'), nil())).toBe(true)
    expect(eq(val("'nil'"), symbol('nil'))).toBe(true)
    expect(eq(val('nil!'), act(nil()))).toBe(true)
    expect(eq(val('nilx'), symbol('nilx'))).toBe(true)
  })

  it('numbers', () => {
    expect(eq(val('0'), int(0n))).toBe(true)
    expect(eq(val('-5'), int(-5n))).toBe(true)
    expect(
      eq(
        val('123456789012345678901234567890'),
        int(123456789012345678901234567890n)
      )
    ).toBe(true)
    expect(eq(val('+7'), symbol('+7'))).toBe(true) // no + sign: a symbol
  })

  it("'_' groups digits and never survives the reading", () => {
    expect(eq(val('1_000_000'), int(1000000n))).toBe(true)
    expect(eq(val('-1_000'), int(-1000n))).toBe(true)
    expect(eq(val('_5'), symbol('_5'))).toBe(true) // no digit in front of it: a symbol
    expect(eq(val('_5_'), symbol('_5_'))).toBe(true) // still that symbol
    expect(() => read('1_')).toThrow(ReaderError)
    expect(() => read('1__000')).toThrow(ReaderError)
    expect(() => read('0_0')).toThrow(ReaderError) // canonicality is judged on the digits
  })

  it('strings', () => {
    expect(eq(val('""'), string(''))).toBe(true)
    expect(eq(val('"hi"'), string('hi'))).toBe(true)
    expect(eq(val('"a\\n\\t\\r\\\\\\"b"'), string('a\n\t\r\\"b'))).toBe(true)
    expect(eq(val('"a\nb"'), string('a\nb'))).toBe(true) // literal newline is legal
  })

  it('symbols', () => {
    expect(eq(val('foo'), symbol('foo'))).toBe(true)
    for (const s of [
      '->',
      '-',
      '<=',
      '+5',
      '*',
      '?',
      'a.b',
      ',',
      'a,b',
      '#',
      '#weird',
      '`tick',
    ]) {
      expect(eq(val(s), symbol(s))).toBe(true)
    }
    expect(eq(val("'has space'"), symbol('has space'))).toBe(true)
    expect(eq(val("''"), symbol(''))).toBe(true)
    expect(eq(val("'a\\'b'"), symbol("a'b"))).toBe(true)
    expect(eq(val("'a!b'"), symbol('a!b'))).toBe(true) // '!' delimits, so it is quoted
  })

  it('bytes', () => {
    expect(eq(val('0x'), bs())).toBe(true)
    expect(eq(val('0xdead'), bs(0xde, 0xad))).toBe(true)
    expect(eq(val('0xDEAD'), bs(0xde, 0xad))).toBe(true) // either case reads
    expect(eq(val('0xde_ad'), bs(0xde, 0xad))).toBe(true)
    expect(eq(val('0xd_e_a_d'), bs(0xde, 0xad))).toBe(true)
  })
})

describe('frames', () => {
  it('lists and records', () => {
    expect(eq(val('[]'), list([]))).toBe(true)
    expect(
      eq(val('[1 two [3]]'), list([int(1n), symbol('two'), list([int(3n)])]))
    ).toBe(true)
    expect(eq(val('(f)'), record([symbol('f')]))).toBe(true)
    expect(eq(val('(f 1 nil)'), record([symbol('f'), int(1n), nil()]))).toBe(
      true
    )
  })

  it("braces without ':' are a set, in canonical order", () => {
    expect(eq(val('{}'), set([]))).toBe(true)
    expect(eq(val('{3 1 2}'), set([int(1n), int(2n), int(3n)]))).toBe(true)
    expect(eq(val('{lone}'), set([symbol('lone')]))).toBe(true)
  })

  it("braces with ':' are a dict, in canonical order", () => {
    expect(eq(val('{:}'), dict([]))).toBe(true)
    const want = dict([
      [symbol('a'), int(1n)],
      [symbol('b'), int(2n)],
    ])
    expect(eq(val('{b: 2 a: 1}'), want)).toBe(true)
    expect(eq(val('{a:1 b:2}'), want)).toBe(true)
    expect(eq(val('{foo:bar}'), dict([[symbol('foo'), symbol('bar')]]))).toBe(
      true
    )
    expect(
      eq(val('{[1]: one}'), dict([[list([int(1n)]), symbol('one')]]))
    ).toBe(true)
  })

  it('the first element decides which', () => {
    expect(() => read('{a b: c}')).toThrow("':' in a set")
    expect(() => read('{a: 1 b}')).toThrow("dict entry needs ':'")
    expect(() => read('{: a}')).toThrow('empty dictionary')
  })

  it('parses nesting', () => {
    expect(
      eq(
        val('[1 [2] {a: "x"}]'),
        list([int(1n), list([int(2n)]), dict([[symbol('a'), string('x')]])])
      )
    ).toBe(true)
  })
})

describe('marks', () => {
  it('an atom is marked behind', () => {
    const v = val('go!')
    expect(isActionable(v)).toBe(true)
    expect(eq(v, act(symbol('go')))).toBe(true)
    expect(eq(val('5!'), act(int(5n)))).toBe(true)
    expect(eq(val('"hi"!'), act(string('hi')))).toBe(true)
    expect(eq(val("'has space'!"), act(symbol('has space')))).toBe(true)
    expect(eq(val("''!"), act(symbol('')))).toBe(true)
    expect(eq(val('0xab!'), act(bs(0xab)))).toBe(true)
    expect(
      eq(val('[go! stop]'), list([act(symbol('go')), symbol('stop')]))
    ).toBe(true)
    expect(eq(val('{go!: 1}'), dict([[act(symbol('go')), int(1n)]]))).toBe(true)
  })

  it('a frame is marked in front', () => {
    expect(eq(val('!(f 1)'), act(record([symbol('f'), int(1n)])))).toBe(true)
    expect(eq(val('![1]'), act(list([int(1n)])))).toBe(true)
    expect(eq(val('!{a}'), act(set([symbol('a')])))).toBe(true)
    expect(eq(val('!{a: 1}'), act(dict([[symbol('a'), int(1n)]])))).toBe(true)
    expect(eq(val('!{:}'), act(dict([])))).toBe(true)
    expect(
      eq(
        val('(f go! !(g))'),
        record([symbol('f'), act(symbol('go')), act(record([symbol('g')]))])
      )
    ).toBe(true)
  })

  it('allows structurally nested marks', () => {
    expect(eq(val('![x! y]'), act(list([act(symbol('x')), symbol('y')])))).toBe(
      true
    )
  })

  it('the mark touches its value, on its side', () => {
    expect(() => read('! (f)')).toThrow('mark separated from its value')
    expect(() => read('!!(f)')).toThrow('repeated mark')
    expect(() => read('!')).toThrow('mark with no value')
    expect(() => read('!x')).toThrow('an atom is marked behind')
    expect(() => read('(f)!')).toThrow('a frame is marked in front')
    expect(() => read('!(f)!')).toThrow('a frame is marked in front')
    expect(() => read('go !')).toThrow('mark with no value') // a separated '!' is no suffix
    expect(() => read('go ! x')).toThrow('mark separated from its value')
    expect(() => read('a!b')).toThrow('a marked atom ends at a delimiter')
    expect(() => read('!;c\n(f)')).toThrow('mark separated from its value')
  })

  it('the mark is part of identity: x and x! are distinct members', () => {
    expect(eq(val('{x x!}'), set([symbol('x'), symbol('x', true)]))).toBe(true)
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

  it('a document may be only noise', () => {
    expect(read(' ; only noise\n')).toEqual([])
    const vs = read('; hi\n1 ; trailing\n2')
    expect(vs).toHaveLength(2)
    expect(eq(vs[0], int(1n))).toBe(true)
    expect(eq(vs[1], int(2n))).toBe(true)
  })
})

describe('rejections', () => {
  it('rejects non-canonical numbers', () => {
    for (const s of ['007', '-0', '1.5', '42px', '1-2', '1.']) {
      expect(() => read(s)).toThrow('not a canonical number')
    }
  })

  it('rejects malformed frames', () => {
    expect(() => read('()')).toThrow('record with no head')
    expect(() => read('{1 1}')).toThrow('duplicate set member')
    expect(() => read('{a: 1 a: 2}')).toThrow('duplicate dict key')
    expect(() => read('{a:}')).toThrow(ReaderError) // missing value
    expect(() => read('[1')).toThrow('unclosed [')
    expect(() => read('(')).toThrow('unclosed (')
    expect(() => read('{')).toThrow('unclosed {')
    expect(() => read('{a: 1')).toThrow('unclosed {')
    expect(() => read('a : b')).toThrow('unexpected :') // ':' outside a dict
  })

  it('rejects malformed bytes', () => {
    expect(() => read('0xabc')).toThrow('even count of hex digits')
    expect(() => read('0xzz')).toThrow('not a hex digit')
    expect(() => read('0x_ab')).toThrow("'_' sits between digits")
    expect(() => read('0xab_')).toThrow("'_' sits between digits")
    expect(() => read('0XAB')).toThrow('not a canonical number') // the prefix is 0x
  })

  it('rejects malformed scalars', () => {
    expect(() => read('"ab')).toThrow('unterminated string')
    expect(() => read("'ab")).toThrow('unterminated symbol')
    expect(() => read('"ab\\')).toThrow('unterminated string') // backslash at EOF
    expect(() => read('"a\\x"')).toThrow('invalid escape')
    expect(() => read('"a\\\'b"')).toThrow('invalid escape') // \' only escapes in a symbol
    expect(() => read('"\uD800"')).toThrow('malformed text') // a lone surrogate
    expect(() => read('\uD800')).toThrow('malformed text')
  })

  it('rejects stray closers', () => {
    for (const s of [')', ']', '}', ':']) {
      expect(() => read(s)).toThrow(`unexpected ${s}`)
    }
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

describe('duplicates', () => {
  it('points at the repeated spelling', () => {
    let err
    try {
      read('{1 2 1}')
    } catch (e) {
      err = e
    }
    expect(err).toBeInstanceOf(ReaderError)
    expect(err.pos).toBe(5)
  })

  it('out-of-order dict keys are fine; text is written by people', () => {
    const want = dict([
      [symbol('a'), int(1n)],
      [symbol('b'), int(2n)],
    ])
    expect(eq(val('{b: 2 a: 1}'), want)).toBe(true)
  })
})

describe('depth', () => {
  it('rejects nesting past maxDepth with a positioned error, not a stack overflow', () => {
    let err
    try {
      read('['.repeat(2000))
    } catch (e) {
      err = e
    }
    expect(err).toBeInstanceOf(ReaderError)
    expect(err.message).toContain('maximum depth')
    expect(err.pos).toBe(1024) // the 1025th opening bracket
  })

  it('accepts nesting up to the limit, and the limit is adjustable', () => {
    const balanced = d => '['.repeat(d) + ']'.repeat(d)
    expect(read(balanced(64))).toHaveLength(1)
    expect(() => read(balanced(64), { maxDepth: 8 })).toThrow('maximum depth')
    expect(read(balanced(9), { maxDepth: 9 })).toHaveLength(1)
  })
})

describe('readSpans', () => {
  it('projects to the same values as read', () => {
    const src = '(entry "k" {1 2 3}) [1 2] go! !{a: 1}'
    const spanned = readSpans(src)
    expect(spanned.map(s => s.value)).toEqual(read(src))
  })

  it('spans an atom by byte offsets, with no children', () => {
    const [s] = readSpans('  42 ')
    expect(s.start).toBe(2)
    expect(s.end).toBe(4)
    expect(s.children).toEqual([])
  })

  it('spans start after leading comments', () => {
    const [s] = readSpans('; c\n 42')
    expect(s.start).toBe(5)
    expect(s.end).toBe(7)
  })

  it("includes an atom's trailing mark in the span", () => {
    const [s] = readSpans('go!')
    expect(s.value.actionable).toBe(true)
    expect(s.start).toBe(0)
    expect(s.end).toBe(3)
  })

  it("includes a frame's leading mark in the span", () => {
    const [s] = readSpans('![1]')
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

  it('spans a marked dict key including its mark', () => {
    const [s] = readSpans('{go!: 1}')
    expect(s.children[0].value.actionable).toBe(true)
    expect([s.children[0].start, s.children[0].end]).toEqual([1, 4])
  })
})

describe('round-trip with canonical encoding', () => {
  it('parse then encode reproduces hand-built values', () => {
    const v = val('(entry "k" {1 2 3})')
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

  it('tolerates a null options bag', () => {
    expect(eq(read('1', null)[0], int(1n))).toBe(true)
  })
})
