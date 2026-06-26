//@ts-check
/** @import {Value} from "@bassline/core/data" */
import { decode } from '@bassline/core/data'
import { NEED_MORE, scanValue } from './scan.js'

/** Default ceiling on a single value's encoded size (16 MiB). */
export const DEFAULT_MAX_VALUE_SIZE = 16 * 1024 * 1024

const EMPTY = new Uint8Array(0)

/**
 * Incremental decoder for the self-framing binary format. Feed it byte chunks;
 * it returns whole Values as they complete and keeps any partial trailing value
 * for the next {@link push}. Each value is sliced and handed to core `decode()`,
 * so canonical-form checks still apply. A value whose header exceeds
 * `maxValueSize` is rejected before its body is buffered. The byte buffer
 * compacts in place, keeping reassembly linear across many small chunks.
 */
export class StreamDecoder {
  /** @param {{ maxValueSize?: number }} [options] */
  constructor({ maxValueSize = DEFAULT_MAX_VALUE_SIZE } = {}) {
    this.maxValueSize = maxValueSize
    /** @type {Uint8Array} live bytes are `[_start, _end)` */
    this._buf = EMPTY
    this._start = 0 // read cursor
    this._end = 0 // write cursor
  }

  /** Bytes buffered awaiting a complete value. */
  get buffered() {
    return this._end - this._start
  }

  /**
   * Append `chunk` and decode every value that is now fully buffered.
   * @param {Uint8Array} chunk
   * @returns {Value[]}
   */
  push(chunk) {
    this._reserve(chunk.length)
    this._buf.set(chunk, this._end)
    this._end += chunk.length

    /** @type {Value[]} */
    const values = []
    // The backing buffer doesn't move until the next push, so this view holds.
    const window = this._buf.subarray(this._start, this._end)
    let off = 0
    while (off < window.length) {
      const total = scanValue(window, off) // throws on a bad descriptor/varint
      if (total === NEED_MORE) break
      if (total > this.maxValueSize) {
        throw new Error(
          `value of ${total} bytes exceeds maxValueSize (${this.maxValueSize})`
        )
      }
      if (off + total > window.length) break // payload still arriving
      values.push(decode(window.subarray(off, off + total)))
      off += total
    }
    this._start += off
    return values
  }

  /**
   * Assert the stream ended on a value boundary; a remainder means a value was
   * truncated.
   * @returns {Value[]} always `[]`, for symmetry with {@link push}
   */
  end() {
    if (this.buffered > 0) {
      throw new Error(
        `stream ended mid-value (${this.buffered} trailing byte(s))`
      )
    }
    return []
  }

  /**
   * Make room for `extra` more bytes, reclaiming the consumed prefix or growing
   * the backing buffer.
   * @param {number} extra
   */
  _reserve(extra) {
    if (this._buf.length - this._end >= extra) return
    const used = this._end - this._start
    if (this._buf.length - used >= extra) {
      this._buf.copyWithin(0, this._start, this._end) // shift live bytes down
    } else {
      let cap = Math.max(this._buf.length * 2, 64)
      while (cap - used < extra) cap *= 2
      const next = new Uint8Array(cap)
      next.set(this._buf.subarray(this._start, this._end), 0)
      this._buf = next
    }
    this._end = used
    this._start = 0
  }
}

/** @param {{ maxValueSize?: number }} [options] */
export const streamDecoder = options => new StreamDecoder(options)
