import { describe, it, expect } from 'vitest'
import { fc, test } from '@fast-check/vitest'
import {
  eq,
  encode,
  nil,
  int,
  text,
  symbol,
  bytes,
  list,
  record,
  dict,
  set,
  withMark,
} from '../src/data.js'
import { fromJSON, toJSON, toValue, JSONError } from '../src/json.js'

const u8 = (...b) => Uint8Array.from(b)
const ceHex = v =>
  [...encode(v)].map(x => x.toString(16).padStart(2, '0')).join('')

describe('toJSON / fromJSON round-trip, by kind', () => {
  const cases = [
    ['nil', nil()],
    ['marked nil', nil(true)],
    ['small int', int(42n)],
    ['negative int', int(-7n)],
    ['int64 max', int(9223372036854775807n)],
    ['int past int64', int(123456789012345678901234567890n)],
    ['int past int64, negative', int(-123456789012345678901234567890n)],
    ['text', text('hello world')],
    ['text with a quote and newline', text('she said "hi"\nthen left')],
    ['symbol', symbol('go')],
    ['empty text', text('')],
    ['bytes', bytes(u8(0xde, 0xad, 0xbe, 0xef))],
    ['empty bytes', bytes(u8())],
    ['bytes holding A0', bytes(u8(0xa0, 0x00, 0xa0))],
    ['list', list([int(1n), text('a'), nil()])],
    ['empty list', list([])],
    ['marked list', withMark(list([int(1n)]))],
    ['record', record([symbol('point'), int(3n), int(4n)])],
    ['record, head only', record([symbol('foo')])],
    [
      'dict',
      dict([
        [symbol('k'), int(1n)],
        [symbol('x'), list([int(2n)])],
      ]),
    ],
    ['empty dict', dict([])],
    ['set', set([nil(), int(0n), text(''), symbol('')])],
    ['empty set', set([])],
    [
      'deep nest with marks',
      withMark(list([dict([[text('a'), withMark(set([int(1n)]))]])])),
    ],
  ]

  it.each(cases)('%s', (_name, v) => {
    expect(eq(fromJSON(toJSON(v)), v)).toBe(true)
  })

  it.each(cases)('%s — stable under a re-encode', (_name, v) => {
    const once = toJSON(v)
    expect(toJSON(fromJSON(once))).toBe(once)
  })
})

describe('the wire shape', () => {
  it('tags every node with its kind', () => {
    expect(JSON.parse(toJSON(int(1n)))).toEqual({ kind: 'number', value: 1 })
    expect(JSON.parse(toJSON(nil()))).toEqual({ kind: 'nil' })
  })

  it('emits the mark only when set, always as true', () => {
    expect(JSON.parse(toJSON(nil(true)))).toEqual({ kind: 'nil', mark: true })
    expect('mark' in JSON.parse(toJSON(nil(false)))).toBe(false)
  })

  it('writes a dict as [key, value] pairs and a set as a bare array', () => {
    expect(JSON.parse(toJSON(dict([[symbol('k'), int(1n)]])))).toEqual({
      kind: 'dict',
      value: [
        [
          { kind: 'symbol', value: 'k' },
          { kind: 'number', value: 1 },
        ],
      ],
    })
    expect(JSON.parse(toJSON(set([int(1n)])))).toEqual({
      kind: 'set',
      value: [{ kind: 'number', value: 1 }],
    })
  })

  it('writes dict and set members in canonical order regardless of input order', () => {
    const d = toJSON(
      dict([
        [int(10n), nil()],
        [int(2n), nil()],
      ])
    )
    const keys = JSON.parse(d).value.map(([k]) => k.value)
    expect(keys).toEqual([2, 10]) // shortlex: "2" before "10"
  })

  it('spells bytes as a lower-case 0x hex string', () => {
    expect(JSON.parse(toJSON(bytes(u8(0x0a, 0xff))))).toEqual({
      kind: 'bytes',
      value: '0x0aff',
    })
  })

  it('keeps a past-2^53 integer as an unquoted JSON number', () => {
    const s = toJSON(int(123456789012345678901234567890n))
    expect(s).toBe('{"kind":"number","value":123456789012345678901234567890}')
  })

  it('takes a space option for pretty output', () => {
    expect(toJSON(int(1n), { space: 2 })).toBe(
      '{\n  "kind": "number",\n  "value": 1\n}'
    )
  })
})

describe('fromJSON recovers integers losslessly', () => {
  it('reads a past-2^53 integer from the text exactly', () => {
    const v = fromJSON(
      '{"kind":"number","value":123456789012345678901234567890}'
    )
    expect(v.value).toBe(123456789012345678901234567890n)
  })

  it('keeps a safe integer a number, a wide one a bigint', () => {
    expect(fromJSON('{"kind":"number","value":42}').value).toBe(42)
    expect(
      fromJSON('{"kind":"number","value":9223372036854775807}').value
    ).toBe(9223372036854775807n)
  })

  it('round-trips the widest corpus integers through text', () => {
    for (const n of [
      9223372036854775807n,
      -9223372036854775808n,
      123456789012345678901234567890n,
      -123456789012345678901234567890n,
    ]) {
      expect(eq(fromJSON(toJSON(int(n))), int(n))).toBe(true)
    }
  })
})

describe('toValue on an already-parsed structure', () => {
  it('reads a plain object tree', () => {
    expect(
      eq(toValue({ kind: 'list', value: [{ kind: 'nil' }] }), list([nil()]))
    ).toBe(true)
  })

  it('refuses an integer past the safe range (precision is already gone)', () => {
    const unsafe = Number.MAX_SAFE_INTEGER + 2
    expect(() => toValue({ kind: 'number', value: unsafe })).toThrow(
      /safe range/
    )
  })
})

describe('refusals', () => {
  const bad = {
    'not an object': '5',
    'array, not a value': '[1, 2]',
    'no kind': '{"value": 1}',
    'kind is not a string': '{"kind": 1}',
    'unknown kind': '{"kind": "blob", "value": 1}',
    'unknown key': '{"kind": "nil", "colour": "red"}',
    'mark is not a boolean': '{"kind": "nil", "mark": 1}',
    'nil carries a value': '{"kind": "nil", "value": null}',
    'missing value': '{"kind": "text"}',
    'number is a float': '{"kind": "number", "value": 1.5}',
    'number is -0': '{"kind": "number", "value": -0}',
    'number in scientific notation': '{"kind": "number", "value": 1e3}',
    'number as a string': '{"kind": "number", "value": "1"}',
    'text is not a string': '{"kind": "text", "value": 5}',
    'text with a lone surrogate': '{"kind": "text", "value": "\\ud800"}',
    'bytes without 0x': '{"kind": "bytes", "value": "dead"}',
    'bytes with an odd hex count': '{"kind": "bytes", "value": "0xabc"}',
    'bytes with a non-hex digit': '{"kind": "bytes", "value": "0xzz"}',
    'record with no head': '{"kind": "record", "value": []}',
    'list members not an array': '{"kind": "list", "value": 5}',
    'dict entry not a pair': '{"kind": "dict", "value": [[{"kind":"nil"}]]}',
    'duplicate dict key':
      '{"kind":"dict","value":[[{"kind":"nil"},{"kind":"nil"}],[{"kind":"nil"},{"kind":"nil"}]]}',
    'duplicate set member':
      '{"kind":"set","value":[{"kind":"nil"},{"kind":"nil"}]}',
    'not JSON at all': '{kind: nil}',
  }

  it.each(Object.entries(bad))('refuses %s', (_name, src) => {
    let err
    try {
      fromJSON(src)
    } catch (e) {
      err = e
    }
    expect(err).toBeInstanceOf(JSONError)
  })

  it('fromJSON rejects a non-string argument', () => {
    expect(() => fromJSON(42)).toThrow(JSONError)
  })
})

// A trimmed value arbitrary — enough shape to exercise every branch of the
// dialect without re-deriving the full generator in data.property.test.js.
const spelling = fc.oneof(
  fc.string(),
  fc.constantFrom('', 'nil', 'a:b', '0x', 'he said "x"', 'a\nb', '\t')
)
const { value } = fc.letrec(tie => ({
  value: fc.oneof(
    { maxDepth: 3 },
    fc.constant(nil()),
    fc.bigInt().map(n => int(n)),
    spelling.map(s => text(s)),
    spelling.map(s => symbol(s)),
    fc.uint8Array().map(b => bytes(b)),
    tie('value').map(v => withMark(v, true)),
    fc.array(tie('value'), { maxLength: 4 }).map(vs => list(vs)),
    fc
      .uniqueArray(tie('value'), { selector: ceHex, maxLength: 4 })
      .map(vs => set(vs)),
    fc
      .uniqueArray(fc.tuple(tie('value'), tie('value')), {
        selector: e => ceHex(e[0]),
        maxLength: 4,
      })
      .map(es => dict(es)),
    fc.array(tie('value'), { minLength: 1, maxLength: 3 }).map(vs => record(vs))
  ),
}))

describe('round-trip', () => {
  test.prop([value])('fromJSON(toJSON(v)) eq v', v => {
    expect(eq(fromJSON(toJSON(v)), v)).toBe(true)
  })

  test.prop([value])('the dialect text is stable across a re-read', v => {
    const s = toJSON(v)
    expect(toJSON(fromJSON(s))).toBe(s)
  })
})
