import { fc, test } from '@fast-check/vitest'
import { describe, it, expect } from 'vitest'
import { fresh, eq, encode, decode, ceKey } from '../src/data.js'

const {
  symbol,
  float,
  int,
  nil,
  bool,
  string,
  bytes,
  list,
  set,
  dict,
  record,
} = fresh

const hex = u8 =>
  [...u8]
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
    .toUpperCase()

const { value } = fc.letrec(tie => ({
  value: fc.oneof(
    { maxDepth: 3 },
    fc.constant(nil()),
    fc.boolean().map(bool),
    fc.bigInt().map(int),
    fc.double().map(float),
    fc.string({ unit: 'grapheme' }).map(string),
    fc.string({ unit: 'grapheme' }).map(symbol),
    fc.uint8Array().map(bytes),
    tie('value').map(v => v.copy(true)),
    fc.array(tie('value'), { maxLength: 4 }).map(list),
    fc.uniqueArray(tie('value'), { selector: ceKey, maxLength: 4 }).map(set),
    fc
      .uniqueArray(fc.tuple(tie('value'), tie('value')), {
        selector: e => ceKey(e[0]),
        maxLength: 4,
      })
      .map(dict),
    fc.array(tie('value'), { maxLength: 3, minLength: 1 }).map(e => record(e))
  ),
}))

describe('round-trip', () => {
  test.prop([value])('decode(encode(v)) eq v', v => {
    expect(eq(decode(encode(v)), v)).toBe(true)
  })

  test.prop([value])(
    'the encoding is canonical (re-encoding the decode is identical)',
    v => {
      const ce = encode(v)
      expect(hex(encode(decode(ce)))).toBe(hex(ce))
    }
  )
})

describe('high-byte ordering', () => {
  // decode validates strictly-ascending CE order, so a wrong sort would throw.
  test.prop([fc.uniqueArray(fc.uint8Array(), { selector: hex, maxLength: 8 })])(
    'byte-string sets re-decode',
    arrs => {
      const s = set(arrs.map(bytes))
      expect(eq(decode(encode(s)), s)).toBe(true)
    }
  )

  test.prop([
    fc.uniqueArray(fc.uint8Array({ minLength: 1 }), {
      selector: hex,
      maxLength: 8,
    }),
  ])('byte-string dict keys re-decode', arrs => {
    const d = dict(arrs.map(a => [bytes(a), nil()]))
    expect(eq(decode(encode(d)), d)).toBe(true)
  })
})

describe('NaN payload normalization', () => {
  test.prop([fc.boolean(), fc.bigInt({ min: 0n, max: (1n << 52n) - 1n })])(
    'any NaN payload encodes canonically',
    (sign, mantissa) => {
      const bits =
        (sign ? 0x8000000000000000n : 0n) |
        0x7ff0000000000000n |
        (mantissa | 1n)
      const dv = new DataView(new ArrayBuffer(8))
      dv.setBigUint64(0, bits)
      const v = float(dv.getFloat64(0))
      expect(hex(encode(v))).toBe('057FF8000000000000')
      expect(eq(decode(encode(v)), v)).toBe(true)
    }
  )
})

describe('mutation resistance', () => {
  test.prop([value])('encode() hands back a private copy', v => {
    encode(v).fill(0) // mutate the returned array
    expect(eq(decode(encode(v)), v)).toBe(true) // value and its cache are untouched
  })

  test.prop([fc.uint8Array({ minLength: 1 })])(
    'bytes copies its input on construction',
    arr => {
      const v = bytes(arr)
      const before = hex(encode(v))
      arr.fill(0xff) // mutate the source array afterwards
      expect(hex(encode(v))).toBe(before)
    }
  )
})

// Independent corpus: (value, expected CE hex) computed by hand from the doc's
// encoding rules — ground truth separate from the implementation.
describe('independent CE corpus', () => {
  const corpus = [
    ['256', int(256n), '04020100'],
    ['-256', int(-256n), '0402FF00'],
    [
      'high-byte set sorts 80 < A0',
      set([bytes(Uint8Array.of(0x80)), bytes(Uint8Array.of(0xa0))]),
      '0C060801800801A0',
    ],
    [
      'high-byte dict keys sort 00 < 80',
      dict([
        [bytes(Uint8Array.of(0x80)), nil()],
        [bytes(Uint8Array.of(0x00)), nil()],
      ]),
      '0A080801000108018001',
    ],
    ['unicode é', string('é'), '0602C3A9'],
    ['emoji', string('\u{1F600}'), '0604F09F9880'],
    ['actionable nested', list([int(1n)]).copy(true), '8903040101'],
    ['empty record', record([symbol('foo')]), '0B050703666F6F'],
    ['NaN', float(NaN), '057FF8000000000000'],
    ['-0.0', float(-0), '058000000000000000'],
  ]

  it.each(corpus)('encodes %s and round-trips', (_name, v, want) => {
    expect(hex(encode(v))).toBe(want)
    expect(eq(decode(encode(v)), v)).toBe(true)
  })
})
