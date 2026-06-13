import { describe, it, expect } from 'vitest'
import * as D from '../src/data.js'

const hex = (u8) =>
  [...u8]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join(' ')
    .toUpperCase()

const bytesOf = (s) => Uint8Array.from(s.trim().split(/\s+/).map((h) => parseInt(h, 16)))

// The 17 positive vectors from data-model.org §7.3. Each is built with a value
// constructor and its expected canonical encoding (hex).
const VECTORS = [
  ['null', D.nul(), '00'],
  ['true', D.bool(true), '02'],
  ['0', D.int(0n), '03 01 00'],
  ['1', D.int(1n), '03 01 01'],
  ['-1', D.int(-1n), '03 01 FF'],
  ['128', D.int(128n), '03 02 00 80'],
  ['255', D.int(255n), '03 02 00 FF'],
  ['1.0', D.float(1.0), '04 3F F0 00 00 00 00 00 00'],
  ['"hi"', D.str('hi'), '05 02 68 69'],
  ['foo (symbol)', D.sym('foo'), '06 03 66 6F 6F'],
  ['#[FF]', D.bytes(Uint8Array.of(0xff)), '07 01 FF'],
  ['[1]', D.list([D.int(1n)]), '08 01 03 01 01'],
  ['{a: 1}', D.dict([[D.sym('a'), D.int(1n)]]), '09 01 06 01 61 03 01 01'],
  // built with keys out of order to exercise canonical sorting
  ['{a: 1, b: 2}', D.dict([[D.sym('b'), D.int(2n)], [D.sym('a'), D.int(1n)]]), '09 02 06 01 61 03 01 01 06 01 62 03 01 02'],
  ['#{1 2}', D.set([D.int(2n), D.int(1n)]), '0B 02 03 01 01 03 01 02'],
  ['<foo 1>', D.record(D.sym('foo'), [D.int(1n)]), '0A 06 03 66 6F 6F 01 03 01 01'],
  ['mark(x)', D.mark(D.sym('x')), '0C 06 01 78'],
]

// The 14 reject vectors from §7.1; decode MUST throw on each.
const REJECTS = [
  ['zero-length integer', '03 00'],
  ['non-minimal integer', '03 02 00 01'],
  ['non-minimal varint', '05 80 00'],
  ['overlong UTF-8', '05 02 C0 80'],
  ['surrogate code point', '05 03 ED A0 80'],
  ['non-canonical NaN', '04 7F F0 00 00 00 00 00 01'],
  ['dict keys out of order', '09 02 06 01 62 03 01 02 06 01 61 03 01 01'],
  ['duplicate dict key', '09 02 06 01 61 03 01 01 06 01 61 03 01 02'],
  ['non-Data dict key', '09 01 0C 06 01 61 03 01 01'],
  ['set members out of order', '0B 02 03 01 02 03 01 01'],
  ['duplicate set member', '0B 02 03 01 01 03 01 01'],
  ['non-Data set member', '0B 01 0C 00'],
  ['double mark prefix', '0C 0C 06 01 78'],
  ['trailing garbage', '00 00'],
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

describe('the mark', () => {
  it('is idempotent', () => {
    expect(D.eq(D.mark(D.mark(D.int(1n))), D.mark(D.int(1n)))).toBe(true)
  })

  it('open inverts mark', () => {
    expect(D.eq(D.open(D.mark(D.int(1n))), D.int(1n))).toBe(true)
  })

  it('open of an unmarked value throws', () => {
    expect(() => D.open(D.int(1n))).toThrow()
  })

  it('makes data? false transitively', () => {
    expect(D.isData(D.list([D.mark(D.int(1n))]))).toBe(false)
    expect(D.isData(D.list([D.int(1n)]))).toBe(true)
  })
})

describe('equality', () => {
  it('eq is total and works on marked values', () => {
    expect(D.eq(D.mark(D.int(1n)), D.mark(D.int(1n)))).toBe(true)
    expect(D.eq(D.mark(D.int(1n)), D.int(1n))).toBe(false)
  })

  it('equal throws off Data', () => {
    expect(() => D.equal(D.mark(D.int(1n)), D.int(1n))).toThrow()
  })

  it('equal coincides with eq on Data', () => {
    expect(D.equal(D.int(1n), D.int(1n))).toBe(true)
    expect(D.equal(D.int(1n), D.int(2n))).toBe(false)
  })

  it('distinguishes int from double', () => {
    expect(D.eq(D.int(1n), D.float(1.0))).toBe(false)
  })

  it('distinguishes a symbol from a same-spelled string', () => {
    expect(D.eq(D.sym('x'), D.str('x'))).toBe(false)
  })

  it('distinguishes {k: null} from {}', () => {
    expect(D.eq(D.dict([[D.sym('k'), D.nul()]]), D.dict([]))).toBe(false)
  })
})

describe('doubles', () => {
  it('treats -0.0 and +0.0 as distinct', () => {
    expect(D.eq(D.float(-0), D.float(0))).toBe(false)
    expect(hex(D.encode(D.float(-0)))).toBe('04 80 00 00 00 00 00 00 00')
  })

  it('canonicalizes NaN', () => {
    expect(hex(D.encode(D.float(NaN)))).toBe('04 7F F8 00 00 00 00 00 00')
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
  it('rejects duplicate keys', () => {
    expect(() => D.dict([[D.sym('a'), D.int(1n)], [D.sym('a'), D.int(2n)]])).toThrow()
  })

  it('rejects a marked key', () => {
    expect(() => D.dict([[D.mark(D.sym('a')), D.int(1n)]])).toThrow()
  })

  it('allows a marked value, becoming non-Data', () => {
    const d = D.dict([[D.sym('a'), D.mark(D.int(1n))]])
    expect(D.isData(d)).toBe(false)
    expect(D.eq(d.get(D.sym('a')), D.mark(D.int(1n)))).toBe(true)
  })

  it('sorts canonically regardless of construction order', () => {
    const a = D.dict([[D.sym('a'), D.int(1n)], [D.sym('b'), D.int(2n)]])
    const b = D.dict([[D.sym('b'), D.int(2n)], [D.sym('a'), D.int(1n)]])
    expect(D.eq(a, b)).toBe(true)
  })
})

describe('sets', () => {
  it('rejects duplicate members', () => {
    expect(() => D.set([D.int(1n), D.int(1n)])).toThrow()
  })

  it('rejects a marked member', () => {
    expect(() => D.set([D.mark(D.int(1n))])).toThrow()
  })

  it('is order-insensitive', () => {
    expect(D.eq(D.set([D.int(1n), D.int(2n)]), D.set([D.int(2n), D.int(1n)]))).toBe(true)
    expect(D.set([D.int(1n)]).has(D.int(1n))).toBe(true)
  })
})

describe('hierarchy', () => {
  it('every value is a BasslineValue', () => {
    expect(D.int(1n)).toBeInstanceOf(D.BasslineValue)
    expect(D.mark(D.int(1n))).toBeInstanceOf(D.BasslineValue)
  })

  it('discriminates by class', () => {
    expect(D.int(1n)).toBeInstanceOf(D.BasslineInt)
    expect(D.float(1.0)).toBeInstanceOf(D.BasslineFloat)
    expect(D.sym('x')).toBeInstanceOf(D.BasslineSymbol)
    expect(D.sym('x')).not.toBeInstanceOf(D.BasslineString)
  })

  it('keeps a value its class through the mark', () => {
    expect(D.mark(D.int(1n))).toBeInstanceOf(D.BasslineInt)
  })
})
