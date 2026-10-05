import { spelling, type Value, type ValueKind } from '../types.ts'
import { ByteBuffer } from './buffer.ts'
import { END, MAX_PAYLOAD, writeHeader } from './util.ts'

const ENC = new TextEncoder()

/** A value's CE bytes. */
export function encode(v: Value): Uint8Array {
  const out = new ByteBuffer()
  encodeInto(v, out)
  return out.toBytes()
}

/** Append a value's CE bytes to `out`. */
export function encodeInto(v: Value, out: ByteBuffer) {
  switch (v.kind) {
    case 'nil':
      out.push(writeHeader(v.kind, v.mark, 0))
      return
    case 'number':
      return scalar(v.kind, v.mark, ENC.encode(spelling(v.payload)), out)
    case 'symbol':
    case 'text':
      // the value refused a lone surrogate, so nothing is replaced here
      return scalar(v.kind, v.mark, ENC.encode(v.payload), out)
    case 'bytes':
      return scalar(v.kind, v.mark, v.payload, out)
    case 'list':
    case 'record':
    case 'dict':
    case 'set':
      // dicts and sets hold their members in CE order already, and a
      // dict's children run key, value, key, value
      out.push(writeHeader(v.kind, v.mark, 0))
      for (const c of v.children()) encodeInto(c, out)
      out.push(END)
      return
  }
}

/** The header, the length in its smallest form, then the payload. */
function scalar(
  kind: ValueKind,
  mark: boolean,
  payload: Uint8Array,
  out: ByteBuffer
) {
  const n = payload.length
  if (n > MAX_PAYLOAD) {
    throw new RangeError(
      `a ${kind} payload of ${n} bytes is past the CE ceiling`
    )
  }
  out.push(writeHeader(kind, mark, n))
  if (n >= 255) {
    out.push(0xff)
    out.push(n >>> 24)
    out.push((n >>> 16) & 0xff)
    out.push((n >>> 8) & 0xff)
    out.push(n & 0xff)
  } else if (n >= 7) {
    out.push(n)
  }
  out.append(payload)
}
