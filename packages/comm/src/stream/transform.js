//@ts-check
/** @import {Value} from "@bassline/core/data" */
import { Transform } from 'node:stream'
import { encode } from '@bassline/core/data'
import { streamDecoder } from './decoder.js'

/**
 * Node `Transform`: bytes in, Values out (object-mode readable). The format is
 * self-framing, so pipe any ordered byte source straight in:
 *
 *     process.stdin.pipe(decodeStream()).on('data', v => …)
 *     for await (const v of process.stdin.pipe(decodeStream())) { … }
 *
 * Malformed or over-large values emit `'error'`; a stream ending mid-value
 * errors on flush.
 */
export class DecodeStream extends Transform {
  /** @param {{ maxValueSize?: number } & import('node:stream').TransformOptions} [options] */
  constructor({ maxValueSize, ...transformOptions } = {}) {
    super({ ...transformOptions, readableObjectMode: true })
    this._dec = streamDecoder({ maxValueSize })
  }

  /**
   * @param {Uint8Array} chunk
   * @param {BufferEncoding} _encoding
   * @param {(error?: Error | null) => void} callback
   */
  _transform(chunk, _encoding, callback) {
    try {
      for (const v of this._dec.push(chunk)) this.push(v)
      callback()
    } catch (err) {
      callback(/** @type {Error} */ (err))
    }
  }

  /** @param {(error?: Error | null) => void} callback */
  _flush(callback) {
    try {
      this._dec.end() // throws if the stream ended mid-value
      callback()
    } catch (err) {
      callback(/** @type {Error} */ (err))
    }
  }
}

/**
 * @param {{ maxValueSize?: number } & import('node:stream').TransformOptions} [options]
 * @returns {DecodeStream}
 */
export const decodeStream = options => new DecodeStream(options)

/**
 * Node `Transform`: Values in (object-mode writable), bytes out. Output is
 * self-framing, so it reassembles via {@link DecodeStream} on the far end:
 *
 *     valueSource.pipe(encodeStream()).pipe(process.stdout)
 */
export class EncodeStream extends Transform {
  /** @param {import('node:stream').TransformOptions} [options] */
  constructor(options = {}) {
    super({ ...options, writableObjectMode: true })
  }

  /**
   * @param {Value} value
   * @param {BufferEncoding} _encoding
   * @param {(error?: Error | null) => void} callback
   */
  _transform(value, _encoding, callback) {
    try {
      this.push(Buffer.from(encode(value)))
      callback()
    } catch (err) {
      callback(/** @type {Error} */ (err))
    }
  }
}

/**
 * @param {import('node:stream').TransformOptions} [options]
 * @returns {EncodeStream}
 */
export const encodeStream = options => new EncodeStream(options)
