import { describe, it, expect } from 'vitest'
import * as D from '../src/data.js'

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
const act = v => v.toActionable()

// (label, value, canonical-encoding hex) — hand-computed from the doc's encoding
// rules: an 8-bit descriptor (actionable flag in the high bit | 7-bit tag), then
// the payload; frames carry a byte-length varint and a sorted body.
const VECTORS = [
  ['nil', D.nil(), '01'],
  ['false', D.bool(false), '02'],
  ['true', D.bool(true), '03'],
  ['0', D.int(0n), '04 01 00'],
  ['1', D.int(1n), '04 01 01'],
  ['-1', D.int(-1n), '04 01 FF'],
  ['128', D.int(128n), '04 02 00 80'],
  ['255', D.int(255n), '04 02 00 FF'],
  ['256', D.int(256n), '04 02 01 00'],
  ['1.0', D.float(1.0), '05 3F F0 00 00 00 00 00 00'],
  ['"hi" string', D.str('hi'), '06 02 68 69'],
  ['foo symbol', D.sym('foo'), '07 03 66 6F 6F'],
  ['#[FF]', D.bytes(Uint8Array.of(0xff)), '08 01 FF'],
  ['[1]', D.list([D.int(1n)]), '09 03 04 01 01'],
  ['[1 2]', D.list([D.int(1n), D.int(2n)]), '09 06 04 01 01 04 01 02'],
  ['{a: 1}', D.dict([[D.sym('a'), D.int(1n)]]), '0A 06 07 01 61 04 01 01'],
  // built with keys out of order to exercise canonical sorting
  [
    '{b: 2, a: 1}',
    D.dict([
      [D.sym('b'), D.int(2n)],
      [D.sym('a'), D.int(1n)],
    ]),
    '0A 0C 07 01 61 04 01 01 07 01 62 04 01 02',
  ],
  ['#{2 1}', D.set([D.int(2n), D.int(1n)]), '0C 06 04 01 01 04 01 02'],
  [
    '<foo 1>',
    D.record(D.sym('foo'), D.int(1n)),
    '0B 08 07 03 66 6F 6F 04 01 01',
  ],
  ['<foo> (empty)', D.record(D.sym('foo')), '0B 05 07 03 66 6F 6F'],
  ['`x (actionable symbol)', act(D.sym('x')), '87 01 78'],
  ['`[1] (actionable list)', act(D.list([D.int(1n)])), '89 03 04 01 01'],
  [
    '[`1 2] (actionable element)',
    D.list([act(D.int(1n)), D.int(2n)]),
    '09 06 84 01 01 04 01 02',
  ],
  [
    '{`a: 1} (actionable key)',
    D.dict([[act(D.sym('a')), D.int(1n)]]),
    '0A 06 87 01 61 04 01 01',
  ],
]

// Each MUST be rejected by decode (the trust boundary for incoming bytes).
const REJECTS = [
  ['error/bad prefix 0x0', '00'],
  ['zero-length integer', '04 00'],
  ['non-minimal integer', '04 02 00 01'],
  ['non-minimal varint', '06 80 00'],
  ['overlong UTF-8', '06 02 C0 80'],
  ['surrogate code point', '06 03 ED A0 80'],
  ['non-canonical NaN', '05 7F F0 00 00 00 00 00 01'],
  ['dict keys out of order', '0A 0C 07 01 62 04 01 02 07 01 61 04 01 01'],
  ['duplicate dict key', '0A 0C 07 01 61 04 01 01 07 01 61 04 01 02'],
  ['set members out of order', '0C 06 04 01 02 04 01 01'],
  ['duplicate set member', '0C 06 04 01 01 04 01 01'],
  ['frame length exceeds input', '09 09 04 01 01'],
  ['frame length mismatch', '09 02 04 01 01'],
  ['trailing garbage', '01 01'],
]

describe('canonical encoding', () => {
  it.each(VECTORS)('encodes %s', (_label, value, want) => {
    expect(hex(D.encode(value))).toBe(want)
  })

  it.each(VECTORS)('round-trips %s', (_label, value) => {
    expect(D.eq(D.decode(D.encode(value)), value)).toBe(true)
  })

  it.each(REJECTS)('rejects %s', (_label, byteStr) => {
    expect(() => D.decode(bytesOf(byteStr))).toThrow()
  })
})

describe('actionable', () => {
  it('toActionable is idempotent', () => {
    expect(D.eq(act(act(D.int(1n))), act(D.int(1n)))).toBe(true)
  })

  it('toStatic inverts toActionable (and is a no-op on a static value)', () => {
    expect(D.eq(act(D.int(1n)).toStatic(), D.int(1n))).toBe(true)
    expect(D.eq(D.int(1n).toStatic(), D.int(1n))).toBe(true)
  })

  it('changes the canonical encoding', () => {
    expect(D.eq(act(D.int(1n)), D.int(1n))).toBe(false)
  })

  it('makes data? false transitively', () => {
    expect(D.isData(D.list([act(D.int(1n))]))).toBe(false)
    expect(D.isData(D.list([D.int(1n)]))).toBe(true)
  })
})

describe('equality', () => {
  it('eq is total and works on actionable values', () => {
    expect(D.eq(act(D.int(1n)), act(D.int(1n)))).toBe(true)
    expect(D.eq(act(D.int(1n)), D.int(1n))).toBe(false)
  })

  it('distinguishes int from double', () => {
    expect(D.eq(D.int(1n), D.float(1.0))).toBe(false)
  })

  it('distinguishes a symbol from a same-spelled string', () => {
    expect(D.eq(D.sym('x'), D.str('x'))).toBe(false)
  })

  it('distinguishes {k: nil} from {}', () => {
    expect(D.eq(D.dict([[D.sym('k'), D.nil()]]), D.dict([]))).toBe(false)
  })
})

describe('doubles', () => {
  it('treats -0.0 and +0.0 as distinct', () => {
    expect(D.eq(D.float(-0), D.float(0))).toBe(false)
    expect(hex(D.encode(D.float(-0)))).toBe('05 80 00 00 00 00 00 00 00')
  })

  it('canonicalizes NaN', () => {
    expect(hex(D.encode(D.float(NaN)))).toBe('05 7F F8 00 00 00 00 00 00')
    expect(D.eq(D.float(NaN), D.float(NaN))).toBe(true)
  })
})

describe('strings', () => {
  it('rejects lone surrogates at construction', () => {
    expect(() => D.str('\uD800')).toThrow()
    expect(() => D.sym('\uDC00')).toThrow()
  })
})

describe('dictionaries', () => {
  it('constructs faithfully', () => {
    expect(() =>
      D.dict([
        [D.sym('a'), D.int(1n)],
        [D.sym('a'), D.int(2n)],
      ])
    ).not.toThrow()
  })

  it('deduplicates keys canonically', () => {
    const d = D.dict([
      [D.sym('a'), D.int(1n)],
      [D.sym('a'), D.int(2n)],
    ])
    expect(d.value.size).toBe(1)
  })

  it('allows an actionable key', () => {
    const d = D.dict([[act(D.sym('a')), D.int(1n)]])
    expect(D.eq(D.decode(D.encode(d)), d)).toBe(true)
  })

  it('allows an actionable value, becoming non-Data', () => {
    const d = D.dict([[D.sym('a'), act(D.int(1n))]])
    expect(D.isData(d)).toBe(false)
    expect(D.eq(d.get(D.sym('a')), act(D.int(1n)))).toBe(true)
  })

  it('sorts canonically regardless of construction order', () => {
    const a = D.dict([
      [D.sym('a'), D.int(1n)],
      [D.sym('b'), D.int(2n)],
    ])
    const b = D.dict([
      [D.sym('b'), D.int(2n)],
      [D.sym('a'), D.int(1n)],
    ])
    expect(D.eq(a, b)).toBe(true)
  })

  it('get returns undefined for a missing key', () => {
    expect(D.dict([[D.sym('a'), D.int(1n)]]).get(D.sym('z'))).toBe(undefined)
  })
})

describe('sets', () => {
  it('constructs faithfully — a duplicate member is not rejected here', () => {
    expect(() => D.set([D.int(1n), D.int(1n)])).not.toThrow()
  })

  it('deduplicates members canonically', () => {
    const s = D.set([D.int(1n), D.int(1n)])
    expect(s.value.length).toBe(1)
  })

  it('is order-insensitive', () => {
    expect(
      D.eq(D.set([D.int(1n), D.int(2n)]), D.set([D.int(2n), D.int(1n)]))
    ).toBe(true)
  })

  it('has checks membership by value', () => {
    expect(D.set([D.int(1n)]).has(D.int(1n))).toBe(true)
    expect(D.set([D.int(1n)]).has(D.int(2n))).toBe(false)
  })
})

describe('hierarchy', () => {
  it('every value is a BasslineValue', () => {
    expect(D.int(1n)).toBeInstanceOf(D.BasslineValue)
    expect(act(D.int(1n))).toBeInstanceOf(D.BasslineValue)
  })

  it('discriminates by class', () => {
    expect(D.nil()).toBeInstanceOf(D.BasslineNil)
    expect(D.int(1n)).toBeInstanceOf(D.BasslineInt)
    expect(D.float(1.0)).toBeInstanceOf(D.BasslineFloat)
    expect(D.sym('x')).toBeInstanceOf(D.BasslineSymbol)
    expect(D.sym('x')).not.toBeInstanceOf(D.BasslineString)
  })

  it('keeps a value its class through toActionable', () => {
    expect(act(D.int(1n))).toBeInstanceOf(D.BasslineInt)
  })
})
