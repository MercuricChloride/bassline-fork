import { fc, test } from '@fast-check/vitest'
import { describe, it, expect } from 'vitest'
import { fresh, eq, encode, ceKey } from '@bassline/core/data'
import { streamDecoder } from '../../src/stream/decoder.js'
import { scanValue, peekVarint, NEED_MORE } from '../../src/stream/scan.js'

const {
  nil,
  bool,
  int,
  float,
  string,
  symbol,
  bytes,
  list,
  set,
  dict,
  record,
} = fresh

// Recursive Value generator, as in core's data.property.test.js.
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
    const a = v.copy(true)
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
    const enc = encode(string('hello world')) // header (0x06 0x0b) + 11 bytes
    const dec = streamDecoder()
    expect(dec.push(enc.subarray(0, 5))).toEqual([]) // header known, payload partial
    expect(dec.buffered).toBe(5)
    const out = dec.push(enc.subarray(5))
    expect(out.length).toBe(1)
    expect(eq(out[0], string('hello world'))).toBe(true)
    expect(dec.buffered).toBe(0)
  })

  it('buffers across a split inside the length varint', () => {
    // 200-byte string: varint is two bytes (0xc8 0x01). Split between them.
    const v = string('x'.repeat(200))
    const enc = encode(v)
    const dec = streamDecoder()
    expect(dec.push(enc.subarray(0, 2))).toEqual([]) // descriptor + first varint byte
    const out = dec.push(enc.subarray(2))
    expect(out.length).toBe(1)
    expect(eq(out[0], v)).toBe(true)
  })

  it('rejects a value larger than maxValueSize from its header alone', () => {
    const enc = encode(bytes(new Uint8Array(100))) // 0x08 0x64 + 100 bytes
    const dec = streamDecoder({ maxValueSize: 8 })
    expect(() => dec.push(enc.subarray(0, 2))).toThrow(/maxValueSize/)
  })

  it('throws on a descriptor that cannot begin a value', () => {
    expect(() => streamDecoder().push(Uint8Array.of(0x00))).toThrow(
      /bad descriptor/
    )
    expect(() => streamDecoder().push(Uint8Array.of(0x1a))).toThrow(
      /bad descriptor/
    )
  })

  it('surfaces a malformed value (caught by core decode) on the slice', () => {
    // Non-minimal integer 0x08 0x02 0x00 0x01 is a complete, well-framed value
    // that core decode() rejects as non-canonical.
    expect(() =>
      streamDecoder().push(Uint8Array.of(0x08, 0x02, 0x00, 0x01))
    ).toThrow(/non-minimal integer/)
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

describe('scanValue / peekVarint', () => {
  it('returns a value size once the header is readable', () => {
    const enc = encode(int(1n)) // 0x04 0x01 0x01
    expect(scanValue(enc)).toBe(3)
    expect(scanValue(enc.subarray(0, 2))).toBe(3) // header complete, payload absent
    expect(scanValue(enc.subarray(0, 1))).toBe(NEED_MORE) // varint not yet present
    expect(scanValue(new Uint8Array(0))).toBe(NEED_MORE)
  })

  it('sizes fixed-width atoms', () => {
    expect(scanValue(encode(nil()))).toBe(1)
    expect(scanValue(encode(bool(true)))).toBe(1)
    expect(scanValue(encode(float(1.5)))).toBe(9)
  })

  it('reads a multi-byte varint and signals incompleteness', () => {
    expect(peekVarint(Uint8Array.of(0x01), 0)).toEqual({ value: 1, size: 1 })
    expect(peekVarint(Uint8Array.of(0x80, 0x01), 0)).toEqual({
      value: 128,
      size: 2,
    })
    expect(peekVarint(Uint8Array.of(0x80), 0)).toBe(NEED_MORE)
  })

  it('rejects a runaway (non-terminating) varint', () => {
    expect(() => peekVarint(new Uint8Array(11).fill(0x80), 0)).toThrow(
      /varint too long/
    )
  })
})
