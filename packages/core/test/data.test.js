import { describe, it, expect } from 'vitest'
import {
  eq,
  isData,
  encode,
  decode,
  withMark,
  at,
  nil,
  int,
  string,
  symbol,
  bytes,
  list,
  record,
  dict,
  set,
} from '../src/data.js'

const hex = u8 =>
  [...u8]
    .map(b => b.toString(16).padStart(2, '0'))
    .join(' ')
    .toUpperCase()

const bytesOf = s =>
  Uint8Array.from(
    s
      .trim()
      .split(/\s+/)
      .map(h => parseInt(h, 16))
  )
const act = v => withMark(v, true)

// (label, value, canonical-encoding hex) — hand-computed from the doc's rules:
// one header byte [tag:4 | mark:1 | len:3]; scalar payloads follow (integers
// as decimal digits); frames hold their encoded children and close with END
// (A0).
const VECTORS = [
  ['nil', nil(), '10'],
  ['`nil', act(nil()), '18'],
  ['0', int(0n), '21 30'],
  ['1', int(1n), '21 31'],
  ['-1', int(-1n), '22 2D 31'],
  ['255', int(255n), '23 32 35 35'],
  ['1234567 (two-byte length)', int(1234567n), '27 07 31 32 33 34 35 36 37'],
  ['"hi" string', string('hi'), '32 68 69'],
  ['foo symbol', symbol('foo'), '43 66 6F 6F'],
  ['`x (actionable symbol)', act(symbol('x')), '49 78'],
  ['#[FF]', bytes(Uint8Array.of(0xff)), '51 FF'],
  ['[] (empty list)', list([]), '60 A0'],
  ['[1]', list([int(1n)]), '60 21 31 A0'],
  ['[1 2]', list([int(1n), int(2n)]), '60 21 31 21 32 A0'],
  ['`[1] (actionable list)', act(list([int(1n)])), '68 21 31 A0'],
  [
    '[`1 2] (actionable element)',
    list([act(int(1n)), int(2n)]),
    '60 29 31 21 32 A0',
  ],
  ['(foo 1)', record([symbol('foo'), int(1n)]), '70 43 66 6F 6F 21 31 A0'],
  ['(foo) (head only)', record([symbol('foo')]), '70 43 66 6F 6F A0'],
  ['{a: 1}', dict([[symbol('a'), int(1n)]]), '80 41 61 21 31 A0'],
  [
    '{`a: 1} (actionable key)',
    dict([[act(symbol('a')), int(1n)]]),
    '80 49 61 21 31 A0',
  ],
  // built with keys out of order to exercise canonical sorting
  [
    '{b: 2, a: 1}',
    dict([
      [symbol('b'), int(2n)],
      [symbol('a'), int(1n)],
    ]),
    '80 41 61 21 31 41 62 21 32 A0',
  ],
  ['#{2 1}', set([int(2n), int(1n)]), '90 21 31 21 32 A0'],
  // a marked and an unmarked member of different types: `nil's header byte
  // (18) sorts before the int's (21) — the mark rides inside the type byte.
  ['#{1 `nil} (mixed mark/type)', set([int(1n), act(nil())]), '90 18 21 31 A0'],
  // an A0 payload byte must not read as END
  [
    '#{#[A0]} (END byte as payload)',
    set([bytes(Uint8Array.of(0xa0))]),
    '90 51 A0 A0',
  ],
]

// Each MUST be rejected by decode (the trust boundary for incoming bytes).
const REJECTS = [
  ['invalid tag 0x0', '00'],
  ['invalid tag 0xb', 'B0'],
  ['invalid tag 0xf', 'F0'],
  ['END at the top level', 'A0'],
  ['END with mark/length bits', 'A8'],
  ['nil with a length', '11'],
  ['frame header with length bits', '61 21 31 A0'],
  ['unterminated frame', '60 21 31'],
  ['record with no head', '70 A0'],
  ['empty integer payload', '20'],
  ['leading-zero integer', '22 30 31'],
  ['negative-zero integer', '22 2D 30'],
  ['plus-signed integer', '22 2B 35'],
  ['non-digit integer', '21 41'],
  ['non-minimal two-byte length', '27 05 31 32 33 34 35'],
  ['non-minimal four-byte length', '37 FF 00 00 00 08'],
  ['overlong UTF-8', '32 C0 80'],
  ['surrogate code point', '33 ED A0 80'],
  ['dict keys out of order', '80 41 62 21 32 41 61 21 31 A0'],
  ['duplicate dict key', '80 41 61 21 31 41 61 21 32 A0'],
  ['dict key missing value', '80 41 61 A0'],
  ['set members out of order', '90 21 32 21 31 A0'],
  ['duplicate set member', '90 21 31 21 31 A0'],
  ['payload past end of input', '23 31 32'],
  ['trailing garbage', '10 10'],
]

describe('canonical encoding', () => {
  it.each(VECTORS)('encodes %s', (_label, value, want) => {
    expect(hex(encode(value))).toBe(want)
  })

  it.each(VECTORS)('round-trips %s', (_label, value) => {
    expect(eq(decode(encode(value)), value)).toBe(true)
  })

  it.each(REJECTS)('rejects %s', (_label, byteStr) => {
    expect(() => decode(bytesOf(byteStr))).toThrow()
  })

  it('uses the four-byte length form past 254', () => {
    const v = string('a'.repeat(300))
    const ce = encode(v)
    expect(hex(ce.subarray(0, 6))).toBe('37 FF 00 00 01 2C')
    expect(ce.length).toBe(306)
    expect(eq(decode(ce), v)).toBe(true)
  })

  it('honors a local length limit', () => {
    const ce = encode(string('a'.repeat(300)))
    expect(() => decode(ce, { maxLength: 100 })).toThrow('length limit')
    expect(() => decode(ce, { maxLength: 300 })).not.toThrow()
  })

  it('rejects nesting past the depth limit', () => {
    const deep = bytesOf('60 '.repeat(5) + '10 ' + 'A0 '.repeat(5))
    expect(() => decode(deep, { maxDepth: 3 })).toThrow('depth')
    expect(() => decode(deep, { maxDepth: 10 })).not.toThrow()
  })
})

describe('actionable', () => {
  it('withMark is idempotent', () => {
    expect(eq(act(act(int(1n))), act(int(1n)))).toBe(true)
  })

  it('withMark(v, false) inverts the mark (and is a no-op on a static value)', () => {
    expect(eq(withMark(act(int(1n)), false), int(1n))).toBe(true)
    expect(eq(withMark(int(1n), false), int(1n))).toBe(true)
  })

  it('changes the canonical encoding', () => {
    expect(eq(act(int(1n)), int(1n))).toBe(false)
  })

  it('makes data? false transitively', () => {
    expect(isData(list([act(int(1n))]))).toBe(false)
    expect(isData(list([int(1n)]))).toBe(true)
  })
})

describe('equality', () => {
  it('eq is total and works on actionable values', () => {
    expect(eq(act(int(1n)), act(int(1n)))).toBe(true)
    expect(eq(act(int(1n)), int(1n))).toBe(false)
  })

  it('distinguishes the int 1 from the string "1" (same payload bytes)', () => {
    expect(eq(int(1n), string('1'))).toBe(false)
  })

  it('distinguishes a symbol from a same-spelled string', () => {
    expect(eq(symbol('x'), string('x'))).toBe(false)
  })

  it('distinguishes {k: nil} from {}', () => {
    expect(eq(dict([[symbol('k'), nil()]]), dict([]))).toBe(false)
  })
})

describe('strings', () => {
  it('rejects lone surrogates at construction', () => {
    expect(() => string('\uD800')).toThrow()
    expect(() => symbol('\uDC00')).toThrow()
  })
})

describe('dictionaries', () => {
  it('constructs faithfully', () => {
    expect(() =>
      dict([
        [symbol('a'), int(1n)],
        [symbol('a'), int(2n)],
      ])
    ).not.toThrow()
  })

  it('deduplicates keys canonically', () => {
    const d = dict([
      [symbol('a'), int(1n)],
      [symbol('a'), int(2n)],
    ])
    expect(d.value.length).toBe(1)
  })

  it('allows an actionable key', () => {
    const d = dict([[act(symbol('a')), int(1n)]])
    expect(eq(decode(encode(d)), d)).toBe(true)
  })

  it('allows an actionable value, becoming non-Data', () => {
    const d = dict([[symbol('a'), act(int(1n))]])
    expect(isData(d)).toBe(false)
    expect(eq(at(d, symbol('a')), act(int(1n)))).toBe(true)
  })

  it('sorts canonically regardless of construction order', () => {
    const a = dict([
      [symbol('a'), int(1n)],
      [symbol('b'), int(2n)],
    ])
    const b = dict([
      [symbol('b'), int(2n)],
      [symbol('a'), int(1n)],
    ])
    expect(eq(a, b)).toBe(true)
  })

  it('dictGet returns undefined for a missing key', () => {
    expect(at(dict([[symbol('a'), int(1n)]]), symbol('z'))).toBe(undefined)
  })
})

describe('sets', () => {
  it('constructs faithfully — a duplicate member is not rejected here', () => {
    expect(() => set([int(1n), int(1n)])).not.toThrow()
  })

  it('deduplicates members canonically', () => {
    const s = set([int(1n), int(1n)])
    expect(s.value.length).toBe(1)
  })

  it('is order-insensitive', () => {
    expect(eq(set([int(1n), int(2n)]), set([int(2n), int(1n)]))).toBe(true)
  })

  it('setHas checks membership by value', () => {
    const a = int(1)
    const b = int(2)
    const s = set([a])
    expect(at(s, a)).toBe(a)
    expect(at(s, b)).toBeUndefined()
  })
})

describe('immutability', () => {
  it('freezes frame internals so a cached CE cannot go stale', () => {
    expect(Object.isFrozen(list([int(1n)]).value)).toBe(true)
    expect(Object.isFrozen(record([symbol('r')]).value)).toBe(true)
    expect(Object.isFrozen(set([int(1n)]).value)).toBe(true)
    expect(Object.isFrozen(dict([]).value)).toBe(true)
  })

  it('values are frozen literals', () => {
    expect(Object.isFrozen(int(1n))).toBe(true)
    expect(Object.isFrozen(list([]))).toBe(true)
    expect(Object.isFrozen(withMark(int(1n), true))).toBe(true)
    expect(Object.isFrozen(decode(encode(record([symbol('r')]))))).toBe(true)
  })
})
