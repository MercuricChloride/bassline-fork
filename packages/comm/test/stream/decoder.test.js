import { fc, test } from '@fast-check/vitest'
import { describe, it, expect } from 'vitest'
import {
  nil,
  int,
  string,
  symbol,
  bytes,
  list,
  set,
  dict,
  record,
  withMark,
  eq,
  encode,
} from '@bassline/core/data'
import { streamDecoder } from '../../src/stream/decoder.js'
import { ValueScanner, scanValue, NEED_MORE } from '../../src/stream/scan.js'

// Recursive Value generator, as in core's tests. Set and dict inputs need no
// uniqueness discipline: the constructors canonicalize.
const { value } = fc.letrec(tie => ({
  value: fc.oneof(
    { maxDepth: 3 },
    fc.constant(nil()),
    fc.bigInt().map(int),
    fc.string({ unit: 'grapheme' }).map(string),
    fc.string({ unit: 'grapheme' }).map(symbol),
    fc.uint8Array().map(bytes),
    tie('value').map(v => withMark(v)),
    fc.array(tie('value'), { maxLength: 4 }).map(list),
    fc.array(tie('value'), { maxLength: 4 }).map(set),
    fc.array(fc.tuple(tie('value'), tie('value')), { maxLength: 4 }).map(dict),
    fc.array(tie('value'), { minLength: 1, maxLength: 3 }).map(record)
  ),
}))

const concatAll = arrs => {
  const out = new Uint8Array(arrs.reduce((n, a) => n + a.length, 0))
  let o = 0
  for (const a of arrs) {
    out.set(a, o)
    o += a.length
  }
  return out
}

// Cut `bytes` at the interior boundaries implied by arbitrary nats.
const splitChunks = (bytes, cuts) => {
  if (bytes.length <= 1) return bytes.length === 0 ? [] : [bytes]
  const points = [...new Set(cuts.map(c => 1 + (c % (bytes.length - 1))))].sort(
    (a, b) => a - b
  )
  const chunks = []
  let prev = 0
  for (const p of points) {
    chunks.push(bytes.subarray(prev, p))
    prev = p
  }
  chunks.push(bytes.subarray(prev))
  return chunks
}

const drain = (chunks, decoder = streamDecoder()) => {
  const out = []
  for (const c of chunks) out.push(...decoder.push(c))
  out.push(...decoder.end()) // asserts the stream ended on a value boundary
  return out
}

describe('stream reassembly (property)', () => {
  test.prop([
    fc.array(value, { maxLength: 8 }),
    fc.array(fc.nat(), { maxLength: 12 }),
  ])(
    'reassembles a value sequence across arbitrary chunk splits',
    (vals, cuts) => {
      const stream = concatAll(vals.map(encode))
      const out = drain(splitChunks(stream, cuts))
      expect(out.length).toBe(vals.length)
      vals.forEach((v, i) => expect(eq(out[i], v)).toBe(true))
    }
  )

  test.prop([fc.array(value, { maxLength: 6 })])(
    'decodes the same sequence one byte at a time',
    vals => {
      const stream = concatAll(vals.map(encode))
      const dec = streamDecoder()
      const out = []
      for (const b of stream) out.push(...dec.push(Uint8Array.of(b)))
      dec.end()
      expect(out.length).toBe(vals.length)
      vals.forEach((v, i) => expect(eq(out[i], v)).toBe(true))
    }
  )

  test.prop([value])('preserves the actionable mark through the stream', v => {
    const a = withMark(v)
    const [out] = drain([encode(a)])
    expect(out.actionable).toBe(true)
    expect(eq(out, a)).toBe(true)
  })
})

describe('StreamDecoder.push', () => {
  it('emits multiple values from a single chunk', () => {
    const vals = [int(1n), string('hi'), list([int(2n), int(3n)])]
    const out = streamDecoder().push(concatAll(vals.map(encode)))
    expect(out.length).toBe(3)
    vals.forEach((v, i) => expect(eq(out[i], v)).toBe(true))
  })

  it('buffers a value whose payload has not fully arrived', () => {
    const enc = encode(string('hello world')) // header (0x37 0x0b) + 11 bytes
    const dec = streamDecoder()
    expect(dec.push(enc.subarray(0, 5))).toEqual([]) // length known, payload partial
    expect(dec.buffered).toBe(5)
    const out = dec.push(enc.subarray(5))
    expect(out.length).toBe(1)
    expect(eq(out[0], string('hello world'))).toBe(true)
    expect(dec.buffered).toBe(0)
  })

  it('buffers across a split inside a medium length', () => {
    // 200-byte string: header 0x37, then the length byte 0xc8. Split between them.
    const v = string('x'.repeat(200))
    const enc = encode(v)
    const dec = streamDecoder()
    expect(dec.push(enc.subarray(0, 1))).toEqual([]) // header, length byte pending
    const out = dec.push(enc.subarray(1))
    expect(out.length).toBe(1)
    expect(eq(out[0], v)).toBe(true)
  })

  it('buffers across splits inside a large length', () => {
    // 300-byte payload: header 0x57, escape 0xff, four big-endian length bytes.
    const v = bytes(new Uint8Array(300))
    const enc = encode(v)
    const dec = streamDecoder()
    expect(dec.push(enc.subarray(0, 2))).toEqual([]) // header + escape
    expect(dec.push(enc.subarray(2, 4))).toEqual([]) // half the length word
    const out = dec.push(enc.subarray(4))
    expect(out.length).toBe(1)
    expect(eq(out[0], v)).toBe(true)
  })

  it('completes a frame only at its closing END byte', () => {
    const v = list([int(1n), list([string('ab')]), nil()])
    const enc = encode(v)
    const dec = streamDecoder()
    expect(dec.push(enc.subarray(0, enc.length - 1))).toEqual([]) // all but END
    const out = dec.push(enc.subarray(enc.length - 1))
    expect(out.length).toBe(1)
    expect(eq(out[0], v)).toBe(true)
  })

  it('rejects an over-large scalar from its announced length alone', () => {
    const enc = encode(bytes(new Uint8Array(100))) // 0x57 0x64 + 100 bytes
    const dec = streamDecoder({ maxValueSize: 8 })
    expect(() => dec.push(enc.subarray(0, 2))).toThrow(/maxValueSize/)
  })

  it('rejects a frame once its buffered prefix exceeds maxValueSize', () => {
    const items = Array.from({ length: 50 }, (_, i) => int(BigInt(i)))
    const enc = encode(list(items))
    const dec = streamDecoder({ maxValueSize: 16 })
    expect(() => dec.push(enc.subarray(0, 32))).toThrow(/maxValueSize/)
  })

  it('rejects an over-large value even when it arrives whole', () => {
    const enc = encode(bytes(new Uint8Array(100)))
    const dec = streamDecoder({ maxValueSize: 8 })
    expect(() => dec.push(enc)).toThrow(/maxValueSize/)
  })

  it('throws on a byte that cannot begin a value', () => {
    expect(() => streamDecoder().push(Uint8Array.of(0x00))).toThrow(
      /bad header/
    )
    expect(() => streamDecoder().push(Uint8Array.of(0xb0))).toThrow(
      /bad header/
    )
    // END carries no flag and no length, so 0xa1-0xaf never occur
    expect(() => streamDecoder().push(Uint8Array.of(0xa5))).toThrow(
      /bad header/
    )
  })

  it('throws on END with no open frame', () => {
    expect(() => streamDecoder().push(Uint8Array.of(0xa0))).toThrow(
      /END with no open frame/
    )
  })

  it('surfaces a malformed value (caught by core decode) on the slice', () => {
    // "01" frames fine as a 2-byte int payload but isn't canonical decimal.
    expect(() => streamDecoder().push(Uint8Array.of(0x22, 0x30, 0x31))).toThrow(
      /non-canonical integer/
    )
    // A 1-byte payload spelled in the medium length form frames fine too,
    // but core decode() rejects the non-minimal spelling.
    expect(() => streamDecoder().push(Uint8Array.of(0x27, 0x01, 0x31))).toThrow(
      /non-minimal length/
    )
  })
})

describe('StreamDecoder.end', () => {
  it('throws when the stream ends mid-value', () => {
    const enc = encode(string('truncated'))
    const dec = streamDecoder()
    dec.push(enc.subarray(0, enc.length - 1))
    expect(() => dec.end()).toThrow(/mid-value/)
  })

  it('is clean on an empty / boundary-aligned stream', () => {
    const dec = streamDecoder()
    expect(dec.end()).toEqual([])
  })
})

describe('scanValue / ValueScanner', () => {
  it('sizes a complete value and reports NEED_MORE otherwise', () => {
    const enc = encode(int(1n)) // 0x21 0x31
    expect(scanValue(enc)).toBe(2)
    expect(scanValue(enc.subarray(0, 1))).toBe(NEED_MORE)
    expect(scanValue(new Uint8Array(0))).toBe(NEED_MORE)
  })

  it('sizes zero-payload atoms', () => {
    expect(scanValue(encode(nil()))).toBe(1)
    expect(scanValue(encode(string('')))).toBe(1)
    expect(scanValue(encode(bytes(new Uint8Array(0))))).toBe(1)
  })

  it('walks a frame to its END byte', () => {
    const enc = encode(list([int(1n), list([nil()])]))
    expect(scanValue(enc)).toBe(enc.length)
    expect(scanValue(enc.subarray(0, enc.length - 1))).toBe(NEED_MORE)
  })

  it('scans at an offset', () => {
    const a = encode(int(7n))
    const b = encode(string('hi'))
    expect(scanValue(concatAll([a, b]), a.length)).toBe(b.length)
  })

  it('resumes across arbitrarily split feeds', () => {
    const enc = encode(record([symbol('blob'), bytes(new Uint8Array(300))]))
    const s = new ValueScanner()
    for (let i = 0; i < enc.length - 1; i++) {
      expect(s.feed(enc, i, i + 1)).toBe(NEED_MORE)
    }
    expect(s.feed(enc, enc.length - 1, enc.length)).toBe(enc.length)
  })

  it('announces a scalar payload before it arrives', () => {
    const enc = encode(bytes(new Uint8Array(300))) // 0x57 0xff <4-byte len> …
    const s = new ValueScanner()
    expect(s.feed(enc, 0, 6)).toBe(NEED_MORE) // header + length only
    expect(s.pending).toBe(300)
  })
})
