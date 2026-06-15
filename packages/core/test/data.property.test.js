import { fc, test } from '@fast-check/vitest'
import { describe, it, expect } from 'vitest'
import * as D from '../src/data.js'

const hex = u8 =>
  [...u8]
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
    .toUpperCase()

// One generator. Actionable values are legal anywhere now (incl. dict keys and
// set members), so there is no separate Data-only generator. uniqueArray with a
// ceKey selector keeps keys/members unique so encoding never sees a duplicate.
const { value } = fc.letrec(tie => ({
  value: fc.oneof(
    { maxDepth: 3 },
    fc.constant(D.nil()),
    fc.boolean().map(D.bool),
    fc.bigInt().map(D.int),
    fc.double().map(D.float),
    fc.string({ unit: 'grapheme' }).map(D.str),
    fc.string({ unit: 'grapheme' }).map(D.sym),
    fc.uint8Array().map(D.bytes),
    tie('value').map(v => v.toActionable()),
    fc.array(tie('value'), { maxLength: 4 }).map(D.list),
    fc
      .uniqueArray(tie('value'), { selector: D.ceKey, maxLength: 4 })
      .map(D.set),
    fc
      .uniqueArray(fc.tuple(tie('value'), tie('value')), {
        selector: e => D.ceKey(e[0]),
        maxLength: 4,
      })
      .map(D.dict),
    fc
      .tuple(tie('value'), fc.array(tie('value'), { maxLength: 3 }))
      .map(e => D.record(e[0], e[1]))
  ),
}))

describe('round-trip', () => {
  test.prop([value])('decode(encode(v)) eq v', v => {
    expect(D.eq(D.decode(D.encode(v)), v)).toBe(true)
  })

  test.prop([value])(
    'the encoding is canonical (re-encoding the decode is identical)',
    v => {
      const ce = D.encode(v)
      expect(hex(D.encode(D.decode(ce)))).toBe(hex(ce))
    }
  )
})

describe('high-byte ordering', () => {
  // decode validates strictly-ascending CE order, so a wrong sort would throw.
  test.prop([fc.uniqueArray(fc.uint8Array(), { selector: hex, maxLength: 8 })])(
    'byte-string sets re-decode',
    arrs => {
      const s = D.set(arrs.map(D.bytes))
      expect(D.eq(D.decode(D.encode(s)), s)).toBe(true)
    }
  )

  test.prop([
    fc.uniqueArray(fc.uint8Array({ minLength: 1 }), {
      selector: hex,
      maxLength: 8,
    }),
  ])('byte-string dict keys re-decode', arrs => {
    const d = D.dict(arrs.map(a => [D.bytes(a), D.nil()]))
    expect(D.eq(D.decode(D.encode(d)), d)).toBe(true)
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
      const v = D.float(dv.getFloat64(0))
      expect(hex(D.encode(v))).toBe('057FF8000000000000')
      expect(D.eq(D.decode(D.encode(v)), v)).toBe(true)
    }
  )
})

describe('mutation resistance', () => {
  test.prop([value])('encode() hands back a private copy', v => {
    D.encode(v).fill(0) // mutate the returned array
    expect(D.eq(D.decode(D.encode(v)), v)).toBe(true) // value and its cache are untouched
  })

  test.prop([fc.uint8Array({ minLength: 1 })])(
    'bytes copies its input on construction',
    arr => {
      const v = D.bytes(arr)
      const before = hex(D.encode(v))
      arr.fill(0xff) // mutate the source array afterwards
      expect(hex(D.encode(v))).toBe(before)
    }
  )
})

// Independent corpus: (value, expected CE hex) computed by hand from the doc's
// encoding rules — ground truth separate from the implementation.
describe('independent CE corpus', () => {
  const corpus = [
    ['256', D.int(256n), '04020100'],
    ['-256', D.int(-256n), '0402FF00'],
    [
      'high-byte set sorts 80 < A0',
      D.set([D.bytes(Uint8Array.of(0x80)), D.bytes(Uint8Array.of(0xa0))]),
      '0C060801800801A0',
    ],
    [
      'high-byte dict keys sort 00 < 80',
      D.dict([
        [D.bytes(Uint8Array.of(0x80)), D.nil()],
        [D.bytes(Uint8Array.of(0x00)), D.nil()],
      ]),
      '0A080801000108018001',
    ],
    ['unicode é', D.str('é'), '0602C3A9'],
    ['emoji', D.str('\u{1F600}'), '0604F09F9880'],
    ['actionable nested', D.list([D.int(1n)]).toActionable(), '8903040101'],
    ['empty record', D.record(D.sym('foo'), []), '0B050703666F6F'],
    ['NaN', D.float(NaN), '057FF8000000000000'],
    ['-0.0', D.float(-0), '058000000000000000'],
  ]

  it.each(corpus)('encodes %s and round-trips', (_name, v, want) => {
    expect(hex(D.encode(v))).toBe(want)
    expect(D.eq(D.decode(D.encode(v)), v)).toBe(true)
  })
})
