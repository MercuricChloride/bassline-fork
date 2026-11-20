import { spelling, type Atom, type Value, type ValueKind } from '../types.ts'
import { steps } from '../ops.ts'
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
  for (const { step, value } of steps(v)) {
    switch (step) {
      case 'open': {
        out.push(writeHeader(value.kind, value.mark, 0))
        break
      }
      case 'atom': {
        writeAtom(value, out)
        break
      }
      case 'close':
        out.push(END)
    }
  }
}

function writeAtom(v: Atom, out: ByteBuffer) {
  switch (v.kind) {
    case 'nil':
      return out.push(writeHeader(v.kind, v.mark, 0))
    case 'number':
      return scalar(v.kind, v.mark, ENC.encode(spelling(v.payload)), out)
    case 'symbol':
    case 'text':
      return scalar(v.kind, v.mark, ENC.encode(v.payload), out)
    case 'bytes':
      return scalar(v.kind, v.mark, v.payload, out)
  }
}

/** The header, the length in its smallest form then the payload */
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
