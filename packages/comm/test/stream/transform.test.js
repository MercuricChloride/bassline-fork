import { describe, it, expect } from 'vitest'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { fresh, eq, encode } from '@bassline/core/data'
import { encodeStream, decodeStream } from '../../src/stream/transform.js'

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

const sample = [
  nil(),
  bool(true),
  int(-7n),
  float(3.5),
  string('héllo 😀'),
  symbol('tag'),
  bytes(Uint8Array.of(1, 2, 3, 255)),
  list([int(1n), int(2n), int(3n)]),
  set([int(1n), int(2n)]),
  dict([
    [symbol('a'), int(1n)],
    [symbol('b'), int(2n)],
  ]),
  record([symbol('point'), int(3n), int(4n)]).copy(true), // actionable
]

const concatAll = arrs => {
  const out = new Uint8Array(arrs.reduce((n, a) => n + a.length, 0))
  let o = 0
  for (const a of arrs) {
    out.set(a, o)
    o += a.length
  }
  return out
}

describe('encodeStream / decodeStream (node Transform)', () => {
  it('round-trips values through encode -> decode', async () => {
    const out = []
    await pipeline(
      Readable.from(sample, { objectMode: true }),
      encodeStream(), // Value -> bytes
      decodeStream(), // bytes -> Value
      async source => {
        for await (const v of source) out.push(v)
      }
    )
    expect(out.length).toBe(sample.length)
    sample.forEach((v, i) => expect(eq(out[i], v)).toBe(true))
  })

  it('reassembles values from arbitrarily chunked bytes', async () => {
    const wire = concatAll(sample.map(encode))
    const chunks = []
    for (let i = 0; i < wire.length; i += 3) {
      chunks.push(Buffer.from(wire.subarray(i, i + 3)))
    }
    const out = []
    await pipeline(Readable.from(chunks), decodeStream(), async source => {
      for await (const v of source) out.push(v)
    })
    expect(out.length).toBe(sample.length)
    sample.forEach((v, i) => expect(eq(out[i], v)).toBe(true))
  })

  it('emits error on a malformed descriptor', async () => {
    const ds = decodeStream()
    ds.resume()
    const error = new Promise(res => ds.on('error', res))
    ds.end(Buffer.of(0x00))
    expect(String(await error)).toMatch(/bad descriptor/)
  })

  it('errors when the stream ends mid-value', async () => {
    const enc = encode(string('truncated'))
    const ds = decodeStream()
    ds.resume()
    const error = new Promise(res => ds.on('error', res))
    ds.end(Buffer.from(enc.subarray(0, enc.length - 1)))
    expect(String(await error)).toMatch(/mid-value/)
  })

  it('honours maxValueSize from the value header alone', async () => {
    const enc = encode(bytes(new Uint8Array(100))) // header 0x08 0x64 + 100 bytes
    const ds = decodeStream({ maxValueSize: 8 })
    ds.resume()
    const error = new Promise(res => ds.on('error', res))
    ds.end(Buffer.from(enc.subarray(0, 2)))
    expect(String(await error)).toMatch(/maxValueSize/)
  })
})
