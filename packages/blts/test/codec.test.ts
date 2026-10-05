import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import {
  cmp,
  CodecError,
  compareEncoded,
  decode,
  decodeAll,
  Decoder,
  encode,
  Incomplete,
  readDocument,
  value,
  type Value,
} from '../src/index.ts'
import { randValue } from './random.ts'

// The shared corpus, read from corpus.bl, and checked against corpus.blb.

const dir = new URL('../../../corpus/', import.meta.url)
const cases = readDocument(
  value,
  readFileSync(new URL('corpus.bl', dir), 'utf8')
) as Value<'record'>[]
const blb = new Uint8Array(readFileSync(new URL('corpus.blb', dir)))

const byHead = (head: string) =>
  cases.filter(c => c.head.kind === 'symbol' && c.head.payload === head)
const field = <K extends Value['kind']>(
  c: Value<'record'>,
  i: number,
  kind: K
) => {
  const v = c.items[i]!
  expect(v.kind).toBe(kind)
  return v as Value<K>
}
const name = (c: Value<'record'>) => field(c, 1, 'symbol').payload

const same = (a: Value, b: Value) => {
  expect(encode(a)).toEqual(encode(b))
  expect(cmp(a, b)).toBe(0)
}

/** What a decoder given these bytes one at a time lands, or why it refused. */
function trickle(bytes: Uint8Array) {
  const d = new Decoder(value)
  const landed: Value[] = []
  try {
    for (const b of bytes) {
      d.add(Uint8Array.of(b))
      landed.push(...d.values())
    }
  } catch (e) {
    return { landed, refused: e as CodecError, pending: d.pending }
  }
  return { landed, refused: null, pending: d.pending }
}

function refusal(f: () => unknown): CodecError {
  try {
    f()
  } catch (e) {
    expect(e).toBeInstanceOf(CodecError)
    return e as CodecError
  }
  throw new Error('not refused')
}

describe('corpus', () => {
  it('reads corpus.json as cases', () => {
    expect(cases.length).toBeGreaterThan(100)
    expect(byHead('ce').length).toBeGreaterThan(20)
  })

  it('corpus.blb decodes to the cases, and they encode back to it byte for byte', () => {
    const fromBlb = decodeAll(value, blb)
    expect(fromBlb.length).toBe(cases.length)
    fromBlb.forEach((v, i) => same(v, cases[i]!))
    const all = Buffer.concat(cases.map(encode))
    expect(new Uint8Array(all)).toEqual(blb)
  })

  it('corpus.blb lands the same fed one byte at a time', () => {
    const t = trickle(blb)
    expect(t.refused).toBeNull()
    expect(t.pending).toBe(false)
    expect(t.landed.length).toBe(cases.length)
    t.landed.forEach((v, i) => same(v, cases[i]!))
  })
})

describe('corpus: ce', () => {
  for (const c of byHead('ce')) {
    it(name(c), () => {
      const v = c.items[2]!
      const want = field(c, 3, 'bytes').payload
      expect(encode(v)).toEqual(want)
      same(decode(value, want), v)
    })
  }
})

describe('corpus: reject', () => {
  for (const c of byHead('reject')) {
    it(name(c), () => {
      const bytes = field(c, 2, 'bytes').payload
      const reason = field(c, 3, 'symbol').payload
      expect(refusal(() => decodeAll(value, bytes)).reason).toBe(reason)
      expect(trickle(bytes).refused?.reason).toBe(reason)
    })
  }
})

describe('corpus: starved', () => {
  for (const c of byHead('starved')) {
    it(name(c), () => {
      const bytes = field(c, 2, 'bytes').payload
      const d = new Decoder(value)
      d.add(bytes)
      expect([...d.values()]).toEqual([])
      expect(d.pending).toBe(true)
      d.finish()
      expect(() => [...d.values()]).toThrow(Incomplete)
      expect(() => decode(value, bytes)).toThrow(Incomplete)
      const t = trickle(bytes)
      expect(t.refused).toBeNull()
      expect(t.landed).toEqual([])
    })
  }
})

describe('order', () => {
  const agree = (values: Value[]) => {
    const bytes = values.map(encode)
    for (let i = 0; i < values.length; i++) {
      for (let j = 0; j < values.length; j++) {
        expect(Math.sign(cmp(values[i]!, values[j]!))).toBe(
          Math.sign(compareEncoded(bytes[i]!, bytes[j]!))
        )
      }
    }
  }

  it('cmp agrees with CE bytes across the corpus values', () => {
    agree(byHead('ce').map(c => c.items[2]!))
  })

  it('cmp agrees with CE bytes across random values', () => {
    for (let n = 0; n < 20; n++)
      agree(Array.from({ length: 30 }, () => randValue(2)))
  })

  it('text orders by UTF-8, not UTF-16', () => {
    // U+E000 is one UTF-16 unit above the surrogates, but three UTF-8 bytes
    // to an astral character's four
    const bmp = value.text('\uE000')
    const astral = value.text('\u{10000}')
    expect(cmp(bmp, astral)).toBeLessThan(0)
    // and within one UTF-8 length, U+FFFF before U+10000, whose first unit
    // is a surrogate below it
    expect(cmp(value.text('\uFFFFa'), value.text('\u{10000}'))).toBeLessThan(0)
  })
})

describe('round trips', () => {
  it('random values encode and decode to themselves', () => {
    for (let n = 0; n < 300; n++) {
      const v = randValue(3)
      const bytes = encode(v)
      const back = decode(value, bytes)
      expect(encode(back)).toEqual(bytes)
      expect(cmp(back, v)).toBe(0)
    }
  })

  it('a concatenation lands whatever the pieces it arrives in', () => {
    const values = Array.from({ length: 40 }, () => randValue(3))
    const bytes = new Uint8Array(Buffer.concat(values.map(encode)))
    const d = new Decoder(value)
    const landed: Value[] = []
    for (let i = 0; i < bytes.length; ) {
      const n = 1 + Math.floor(Math.random() * 64)
      d.add(bytes.subarray(i, i + n))
      landed.push(...d.values())
      i += n
    }
    d.finish()
    expect([...d.values()]).toEqual([])
    expect(landed.length).toBe(values.length)
    landed.forEach((v, i) => expect(cmp(v, values[i]!)).toBe(0))
  })
})

describe('edges', () => {
  it('length tiers break at 6/7 and 254/255', () => {
    const header = (n: number) =>
      encode(value.bytes(new Uint8Array(n))).subarray(0, 6)
    expect(header(6)[0]).toBe(0x56)
    expect([...header(7).subarray(0, 2)]).toEqual([0x57, 7])
    expect([...header(254).subarray(0, 2)]).toEqual([0x57, 254])
    expect([...header(255)]).toEqual([0x57, 0xff, 0, 0, 0, 0xff])
    expect(encode(value.text('\u00E9'.repeat(4)))[0]).toBe(0x37) // 8 bytes, not 4 units
  })

  it('integers keep every digit', () => {
    expect(encode(value.number(1e21))).toEqual(encode(value.number(10n ** 21n)))
    const wide = 10n ** 400n + 1n
    const back = decode(value, encode(value.number(wide))) as Value<'number'>
    expect(back.payload).toBe(wide)
    expect(decode(value, encode(value.number(2 ** 53 - 1))).kind).toBe('number')
    const past = decode(
      value,
      encode(value.number(2n ** 53n + 1n))
    ) as Value<'number'>
    expect(past.payload).toBe(2n ** 53n + 1n)
    expect(() => value.number(1.5)).toThrow(TypeError)
    expect(() => value.number(NaN)).toThrow(TypeError)
  })

  it('each integer has one host form', () => {
    expect(value.number(5n).payload).toBe(5)
    expect(value.number(-0).payload).toBe(0)
    expect(Object.is(value.number(-0).payload, 0)).toBe(true)
    expect(value.number(2 ** 60).payload).toBe(2n ** 60n)
    expect(value.number(2n ** 53n).payload).toBe(2n ** 53n)
    expect(value.number(2 ** 53 - 1).payload).toBe(2 ** 53 - 1)
  })

  it('text is kept as given', () => {
    const nfc = value.text('\u00E9')
    const nfd = value.text('e\u0301')
    expect(cmp(nfc, nfd)).not.toBe(0)
    const bom = decode(value, encode(value.text('\uFEFFx'))) as Value<'text'>
    expect(bom.payload).toBe('\uFEFFx')
    expect(() => value.text('\uD800')).toThrow(TypeError)
    expect(() => value.sym('a\uDC00')).toThrow(TypeError)
  })

  it('a tree from a dict or set is its own', () => {
    const d = value.dict([[value.sym('a'), value.number(1)]])
    const t = d.tree()
    t.set(value.sym('b'), value.number(2))
    const d2 = value.dict(t)
    expect(d.length).toBe(1)
    expect(d2.get(value.sym('b'))).toEqual(value.number(2))
    const s = value.set([value.sym('a')])
    const st = s.tree()
    st.add(value.sym('b'))
    expect(s.has(value.sym('b'))).toBe(false)
    expect(value.set(st).length).toBe(2)
  })

  it('marks are per value', () => {
    const v = value.list([value.sym('go')], true)
    const back = decode(value, encode(v)) as Value<'list'>
    expect(back.mark).toBe(true)
    expect(back.items[0]!.mark).toBe(false)
  })

  it('refuses nesting past the depth limit', () => {
    let v: Value = value.nil()
    for (let i = 0; i < 9; i++) v = value.list([v])
    const bytes = encode(v)
    expect(decode(value, bytes, { maxDepth: 9 }).kind).toBe('list')
    expect(refusal(() => decode(value, bytes, { maxDepth: 8 })).reason).toBe(
      'max-depth'
    )
  })

  it('refuses a value past the size cap, however it arrives', () => {
    const v = value.list(Array.from({ length: 20 }, (_, i) => value.number(i)))
    const bytes = encode(v)
    expect(decode(value, bytes, { maxValueBytes: bytes.length }).kind).toBe(
      'list'
    )
    expect(
      refusal(() => decode(value, bytes, { maxValueBytes: bytes.length - 1 }))
        .reason
    ).toBe('max-value-bytes')
    const d = new Decoder(value, { maxValueBytes: bytes.length - 1 })
    const e = refusal(() => {
      for (const b of bytes) {
        d.add(Uint8Array.of(b))
        ;[...d.values()]
      }
    })
    expect(e.reason).toBe('max-value-bytes')
    // a scalar is refused from its header, before its payload arrives
    const big = new Decoder(value, { maxValueBytes: 100 })
    big.add(Uint8Array.of(0x57, 0xff, 0, 0, 1, 0))
    expect(refusal(() => [...big.values()]).reason).toBe('max-value-bytes')
  })

  it('a refused decoder stays refused', () => {
    const d = new Decoder(value)
    d.add(Uint8Array.of(0x10, 0x00, 0x10))
    const got: Value[] = []
    const e = refusal(() => {
      for (const v of d.values()) got.push(v)
    })
    expect(got.length).toBe(1)
    expect(e.reason).toBe('invalid-tag')
    expect(d.failed).toBe(e)
    expect(() => [...d.values()]).toThrow(e)
    expect(() => d.add(Uint8Array.of(0x10))).toThrow(e)
  })

  it('stopping early leaves the rest for a later pull', () => {
    const d = new Decoder(value)
    d.add(
      new Uint8Array(
        Buffer.concat([encode(value.number(1)), encode(value.number(2))])
      )
    )
    for (const v of d.values()) {
      expect((v as Value<'number'>).payload).toBe(1)
      break
    }
    expect([...d.values()].map(v => (v as Value<'number'>).payload)).toEqual([
      2,
    ])
    d.finish()
    expect([...d.values()]).toEqual([])
  })

  it('one value is exactly one', () => {
    expect(refusal(() => decode(value, new Uint8Array())).reason).toBe(
      'no-value'
    )
    expect(refusal(() => decode(value, Uint8Array.of(0x10, 0x10))).reason).toBe(
      'several-values'
    )
    expect(refusal(() => decode(value, Uint8Array.of(0x10, 0x60))).reason).toBe(
      'several-values'
    )
    expect(refusal(() => decode(value, Uint8Array.of(0x10, 0xa0))).reason).toBe(
      'end-at-top'
    )
  })
})
