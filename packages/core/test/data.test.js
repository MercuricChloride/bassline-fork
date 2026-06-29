import { describe, it, expect } from 'vitest'
import { fresh, eq, isData, encode, decode } from '../src/data.js'

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
const act = v => v.copy(true)

// (label, value, canonical-encoding hex) — hand-computed from the doc's encoding
// rules: an 8-bit descriptor (7-bit tag in the high bits | actionable flag in the
// low bit, i.e. byte = (tag << 1) | actionable), then the payload; frames carry a
// byte-length varint and a sorted body.
const VECTORS = [
  ['nil', fresh.nil(), '02'],
  ['false', fresh.bool(false), '04'],
  ['true', fresh.bool(true), '06'],
  ['0', fresh.int(0n), '08 01 00'],
  ['1', fresh.int(1n), '08 01 01'],
  ['-1', fresh.int(-1n), '08 01 FF'],
  ['128', fresh.int(128n), '08 02 00 80'],
  ['255', fresh.int(255n), '08 02 00 FF'],
  ['256', fresh.int(256n), '08 02 01 00'],
  ['1.0', fresh.float(1.0), '0A 3F F0 00 00 00 00 00 00'],
  ['"hi" string', fresh.string('hi'), '0C 02 68 69'],
  ['foo symbol', fresh.symbol('foo'), '0E 03 66 6F 6F'],
  ['#[FF]', fresh.bytes(Uint8Array.of(0xff)), '10 01 FF'],
  ['[1]', fresh.list([fresh.int(1n)]), '12 03 08 01 01'],
  [
    '[1 2]',
    fresh.list([fresh.int(1n), fresh.int(2n)]),
    '12 06 08 01 01 08 01 02',
  ],
  [
    '{a: 1}',
    fresh.dict([[fresh.symbol('a'), fresh.int(1n)]]),
    '14 06 0E 01 61 08 01 01',
  ],
  // built with keys out of order to exercise canonical sorting
  [
    '{b: 2, a: 1}',
    fresh.dict([
      [fresh.symbol('b'), fresh.int(2n)],
      [fresh.symbol('a'), fresh.int(1n)],
    ]),
    '14 0C 0E 01 61 08 01 01 0E 01 62 08 01 02',
  ],
  [
    '#{2 1}',
    fresh.set([fresh.int(2n), fresh.int(1n)]),
    '18 06 08 01 01 08 01 02',
  ],
  // a marked and an unmarked member of different types: the actionable nil sorts
  // by its type tag (lowest), not pushed to the end by its mark — type-major order.
  [
    '#{1 `nil} (mixed mark/type)',
    fresh.set([fresh.int(1n), act(fresh.nil())]),
    '18 04 03 08 01 01',
  ],
  [
    '(foo 1)',
    fresh.record([fresh.symbol('foo'), fresh.int(1n)]),
    '16 08 0E 03 66 6F 6F 08 01 01',
  ],
  [
    '(foo) (empty)',
    fresh.record([fresh.symbol('foo')]),
    '16 05 0E 03 66 6F 6F',
  ],
  ['`x (actionable symbol)', act(fresh.symbol('x')), '0F 01 78'],
  [
    '`[1] (actionable list)',
    act(fresh.list([fresh.int(1n)])),
    '13 03 08 01 01',
  ],
  [
    '[`1 2] (actionable element)',
    fresh.list([act(fresh.int(1n)), fresh.int(2n)]),
    '12 06 09 01 01 08 01 02',
  ],
  [
    '{`a: 1} (actionable key)',
    fresh.dict([[act(fresh.symbol('a')), fresh.int(1n)]]),
    '14 06 0F 01 61 08 01 01',
  ],
]

// Each MUST be rejected by decode (the trust boundary for incoming bytes).
const REJECTS = [
  ['error/bad prefix 0x0', '00'],
  ['zero-length integer', '08 00'],
  ['non-minimal integer', '08 02 00 01'],
  ['non-minimal varint', '0C 80 00'],
  ['overlong UTF-8', '0C 02 C0 80'],
  ['surrogate code point', '0C 03 ED A0 80'],
  ['non-canonical NaN', '0A 7F F0 00 00 00 00 00 01'],
  ['dict keys out of order', '14 0C 0E 01 62 08 01 02 0E 01 61 08 01 01'],
  ['duplicate dict key', '14 0C 0E 01 61 08 01 01 0E 01 61 08 01 02'],
  ['set members out of order', '18 06 08 01 02 08 01 01'],
  ['duplicate set member', '18 06 08 01 01 08 01 01'],
  ['frame length exceeds input', '12 09 08 01 01'],
  ['frame length mismatch', '12 02 08 01 01'],
  ['trailing garbage', '02 02'],
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
})

describe('actionable', () => {
  it('toActionable is idempotent', () => {
    expect(eq(act(act(fresh.int(1n))), act(fresh.int(1n)))).toBe(true)
  })

  it('toStatic inverts toActionable (and is a no-op on a static value)', () => {
    expect(eq(act(fresh.int(1n)).copy(false), fresh.int(1n))).toBe(true)
    expect(eq(fresh.int(1n).copy(false), fresh.int(1n))).toBe(true)
  })

  it('changes the canonical encoding', () => {
    expect(eq(act(fresh.int(1n)), fresh.int(1n))).toBe(false)
  })

  it('makes data? false transitively', () => {
    expect(isData(fresh.list([act(fresh.int(1n))]))).toBe(false)
    expect(isData(fresh.list([fresh.int(1n)]))).toBe(true)
  })
})

describe('equality', () => {
  it('eq is total and works on actionable values', () => {
    expect(eq(act(fresh.int(1n)), act(fresh.int(1n)))).toBe(true)
    expect(eq(act(fresh.int(1n)), fresh.int(1n))).toBe(false)
  })

  it('distinguishes int from double', () => {
    expect(eq(fresh.int(1n), fresh.float(1.0))).toBe(false)
  })

  it('distinguishes a symbol from a same-spelled string', () => {
    expect(eq(fresh.symbol('x'), fresh.string('x'))).toBe(false)
  })

  it('distinguishes {k: nil} from {}', () => {
    expect(
      eq(fresh.dict([[fresh.symbol('k'), fresh.nil()]]), fresh.dict([]))
    ).toBe(false)
  })
})

describe('doubles', () => {
  it('treats -0.0 and +0.0 as distinct', () => {
    expect(eq(fresh.float(-0), fresh.float(0))).toBe(false)
    expect(hex(encode(fresh.float(-0)))).toBe('0A 80 00 00 00 00 00 00 00')
  })

  it('canonicalizes NaN', () => {
    expect(hex(encode(fresh.float(NaN)))).toBe('0A 7F F8 00 00 00 00 00 00')
    expect(eq(fresh.float(NaN), fresh.float(NaN))).toBe(true)
  })
})

describe('strings', () => {
  it('rejects lone surrogates at construction', () => {
    expect(() => fresh.string('\uD800')).toThrow()
    expect(() => fresh.symbol('\uDC00')).toThrow()
  })
})

describe('dictionaries', () => {
  it('constructs faithfully', () => {
    expect(() =>
      fresh.dict([
        [fresh.symbol('a'), fresh.int(1n)],
        [fresh.symbol('a'), fresh.int(2n)],
      ])
    ).not.toThrow()
  })

  it('deduplicates keys canonically', () => {
    const d = fresh.dict([
      [fresh.symbol('a'), fresh.int(1n)],
      [fresh.symbol('a'), fresh.int(2n)],
    ])
    expect(d.length).toBe(1)
  })

  it('allows an actionable key', () => {
    const d = fresh.dict([[act(fresh.symbol('a')), fresh.int(1n)]])
    expect(eq(decode(encode(d)), d)).toBe(true)
  })

  it('allows an actionable value, becoming non-Data', () => {
    const d = fresh.dict([[fresh.symbol('a'), act(fresh.int(1n))]])
    expect(isData(d)).toBe(false)
    expect(eq(d.get(fresh.symbol('a')), act(fresh.int(1n)))).toBe(true)
  })

  it('sorts canonically regardless of construction order', () => {
    const a = fresh.dict([
      [fresh.symbol('a'), fresh.int(1n)],
      [fresh.symbol('b'), fresh.int(2n)],
    ])
    const b = fresh.dict([
      [fresh.symbol('b'), fresh.int(2n)],
      [fresh.symbol('a'), fresh.int(1n)],
    ])
    expect(eq(a, b)).toBe(true)
  })

  it('get returns undefined for a missing key', () => {
    expect(
      fresh.dict([[fresh.symbol('a'), fresh.int(1n)]]).get(fresh.symbol('z'))
    ).toBe(undefined)
  })
})

describe('sets', () => {
  it('constructs faithfully — a duplicate member is not rejected here', () => {
    expect(() => fresh.set([fresh.int(1n), fresh.int(1n)])).not.toThrow()
  })

  it('deduplicates members canonically', () => {
    const s = fresh.set([fresh.int(1n), fresh.int(1n)])
    expect(s.length).toBe(1)
  })

  it('is order-insensitive', () => {
    expect(
      eq(
        fresh.set([fresh.int(1n), fresh.int(2n)]),
        fresh.set([fresh.int(2n), fresh.int(1n)])
      )
    ).toBe(true)
  })

  it('has checks membership by value', () => {
    expect(fresh.set([fresh.int(1n)]).has(fresh.int(1n))).toBe(true)
    expect(fresh.set([fresh.int(1n)]).has(fresh.int(2n))).toBe(false)
  })
})
