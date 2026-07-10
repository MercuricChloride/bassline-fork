import { fc, test } from '@fast-check/vitest'
import { describe, it, expect } from 'vitest'
import {
  eq,
  encode,
  decode,
  withMark,
  symbol,
  int,
  nil,
  string,
  bytes,
  list,
  set,
  dict,
  record,
} from '../src/data.js'
import { read, print } from '../src/text/index.js'

const hex = u8 =>
  [...u8]
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
    .toUpperCase()

const ceHex = v => hex(encode(v))

// Spellings that once broke, or nearly break, the textual syntax: reserved
// words, delimiters, whitespace (the comma!), number look-alikes, escapes.
// Mixed into the grapheme generators so the text round-trip stays honest.
const spelling = fc.oneof(
  fc.string({ unit: 'grapheme' }),
  fc.constantFrom(
    '',
    'nil',
    'a,b',
    'has space',
    'a:b',
    'a;b',
    "it's",
    '"quoted"',
    'back\\slash',
    'new\nline',
    '`x',
    '#[',
    '->',
    '-',
    '-5',
    '007',
    '-0',
    '1.5',
    '(',
    ')',
    '[',
    ']',
    '{',
    '}'
  )
)

const { value } = fc.letrec(tie => ({
  value: fc.oneof(
    { maxDepth: 3 },
    fc.constant(nil()),
    fc.bigInt().map(int),
    spelling.map(string),
    spelling.map(symbol),
    fc.uint8Array().map(bytes),
    tie('value').map(v => withMark(v, true)),
    fc.array(tie('value'), { maxLength: 4 }).map(list),
    fc.uniqueArray(tie('value'), { selector: ceHex, maxLength: 4 }).map(set),
    fc
      .uniqueArray(fc.tuple(tie('value'), tie('value')), {
        selector: e => ceHex(e[0]),
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

  test.prop([value])('read(print(v)) yields exactly v', v => {
    const vs = read(print(v))
    expect(vs.length).toBe(1)
    expect(eq(vs[0], v)).toBe(true)
  })
})

describe('encoding is total over depth', () => {
  // The recursive encoder died near 3000 levels. Depth is capped here only
  // because the per-node CE cache makes deep chains quadratic in time —
  // this pins totality, not speed.
  it('encodes values far deeper than the call stack', () => {
    let v = int(1n)
    for (let i = 0; i < 10_000; i++) v = list([v])
    const ce = encode(v)
    // one header and one END per level, two bytes for the innermost int
    expect(ce.length).toBe(2 * 10_000 + 2)
    expect(ce[0]).toBe(0x60)
    expect(ce[ce.length - 1]).toBe(0xa0)
  })

  it('round-trips through decode within the decoder depth limit', () => {
    let v = int(1n)
    for (let i = 0; i < 1000; i++) v = list([v])
    expect(eq(decode(encode(v)), v)).toBe(true)
  })
})

describe('high-byte ordering', () => {
  // decode validates strictly-ascending CE order, so a wrong sort would
  // throw. Bytestrings holding A0 also prove a payload byte never reads as
  // END.
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

describe('length tiers', () => {
  // 0..600 crosses both boundaries: 6/7 (inline to two-byte) and 254/255
  // (two-byte to four-byte).
  test.prop([fc.integer({ min: 0, max: 600 })])(
    'every payload length round-trips',
    n => {
      const v = string('x'.repeat(n))
      expect(eq(decode(encode(v)), v)).toBe(true)
    }
  )

  test.prop([fc.bigInt({ min: -(10n ** 30n), max: 10n ** 30n })])(
    'integers of any digit count round-trip',
    n => {
      const v = int(n)
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

// Independent corpus: (value, expected CE hex) computed by hand from the
// doc's encoding rules — ground truth separate from the implementation.
describe('independent CE corpus', () => {
  const corpus = [
    ['256', int(256n), '23323536'],
    ['-256', int(-256n), '242D323536'],
    ['seven-digit int', int(1234567n), '270731323334353637'],
    [
      'high-byte set sorts 80 < A0',
      set([bytes(Uint8Array.of(0xa0)), bytes(Uint8Array.of(0x80))]),
      '90518051A0A0',
    ],
    [
      'high-byte dict keys sort 00 < 80',
      dict([
        [bytes(Uint8Array.of(0x80)), nil()],
        [bytes(Uint8Array.of(0x00)), nil()],
      ]),
      '80510010518010A0',
    ],
    ['unicode é', string('é'), '32C3A9'],
    ['emoji', string('\u{1F600}'), '34F09F9880'],
    ['actionable nested', withMark(list([int(1n)]), true), '682131A0'],
    ['record, head only', record([symbol('foo')]), '7043666F6FA0'],
  ]

  it.each(corpus)('encodes %s and round-trips', (_name, v, want) => {
    expect(hex(encode(v))).toBe(want)
    expect(eq(decode(encode(v)), v)).toBe(true)
  })
})
