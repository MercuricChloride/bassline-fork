// @ts-check

// The CE writer: a byte sink that knows the header rules and nothing about
// any in-memory value type. A caller drives it with putNil / putScalar /
// open / close (or the frame helper) and reads `.bytes` once nothing is open.
// The driver is the caller's: value/ce.js walks a value iteratively so an
// arbitrarily deep value still encodes.

import {
  CodecError,
  END,
  MAX_PAYLOAD,
  headerByte,
  isFrameKind,
  isScalarKind,
} from './header.js'
import { ByteBuffer } from './buffer.js'

export { CodecError }

export class Encoder {
  #buf = new ByteBuffer()
  #depth = 0

  /** @param {boolean} [mark] */
  putNil(mark = false) {
    this.#buf.push(headerByte('nil', mark, 0))
  }

  /**
   * @param {string} kind one of number, text, symbol, bytes
   * @param {boolean} mark
   * @param {Uint8Array} payload
   */
  putScalar(kind, mark, payload) {
    if (!isScalarKind(kind)) throw new CodecError(kind + ' is not a scalar')
    const len = payload.length
    if (len > MAX_PAYLOAD) throw new CodecError('payload too large')
    this.#buf.push(headerByte(kind, mark, len))
    this.#writeLength(len)
    this.#buf.append(payload)
  }

  /**
   * The length prefix after a scalar header: nothing for a length that fits
   * the header's low three bits, one byte up to 254, else 0xFF then a
   * big-endian uint32. Each tier is mandatory in its range.
   * @param {number} len
   */
  #writeLength(len) {
    if (len <= 6) return
    if (len <= 254) {
      this.#buf.push(len)
      return
    }
    this.#buf.push(0xff)
    this.#buf.push((len >>> 24) & 0xff)
    this.#buf.push((len >>> 16) & 0xff)
    this.#buf.push((len >>> 8) & 0xff)
    this.#buf.push(len & 0xff)
  }

  /**
   * @param {string} kind
   * @param {boolean} [mark]
   */
  open(kind, mark = false) {
    if (!isFrameKind(kind)) throw new CodecError(kind + ' is not a frame')
    this.#buf.push(headerByte(kind, mark, 0))
    this.#depth++
  }

  close() {
    if (this.#depth === 0) throw new CodecError('close with no open frame')
    this.#depth--
    this.#buf.push(END)
  }

  /**
   * @param {string} kind
   * @param {boolean} mark
   * @param {() => void} body
   */
  frame(kind, mark, body) {
    this.open(kind, mark)
    body()
    this.close()
  }

  get pending() {
    return this.#depth > 0
  }

  /** The bytes written so far, as a fresh copy. Throws while a frame is open. */
  get bytes() {
    if (this.#depth !== 0) throw new CodecError('encoder has an open frame')
    return this.#buf.bytes().slice()
  }
}
