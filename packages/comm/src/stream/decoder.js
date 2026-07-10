//@ts-check
/** @import {Value} from "@bassline/core/data" */
import { decode } from '@bassline/core/data'
import { NEED_MORE, ValueScanner } from './scan.js'

/** Default ceiling on a single value's encoded size (16 MiB). */
export const DEFAULT_MAX_VALUE_SIZE = 16 * 1024 * 1024

const EMPTY = new Uint8Array(0)

/**
 * Incremental decoder for the Bassline binary format. Feed it byte
 * chunks; it returns whole Values as they complete and keeps any partial
 * trailing value for the next {@link push}. Boundaries come from a
 * {@link ValueScanner} that walks each byte once, whatever the chunking, and
 * each completed span is handed to core `decode()`, so canonical-form checks
 * still apply. `maxValueSize` doesn't wait for a value to complete: a scalar
 * is refused from its announced length before the payload is buffered, a
 * frame as soon as its buffered prefix passes the limit. The byte buffer
 * compacts in place, keeping reassembly linear across many small chunks.
 */
export class StreamDecoder {
  /** @param {{ maxValueSize?: number }} [options] */
  constructor({ maxValueSize = DEFAULT_MAX_VALUE_SIZE } = {}) {
    this.maxValueSize = maxValueSize
    /** @type {Uint8Array} live bytes are `[_start, _end)` */
    this._buf = EMPTY
    this._start = 0 // read cursor: where the value being scanned begins
    this._end = 0 // write cursor
    this._scanPos = 0 // bytes in `[_start, _scanPos)` are already scanned
    this._scanner = new ValueScanner()
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
    while (this._scanPos < this._end) {
      const end = this._scanner.feed(this._buf, this._scanPos, this._end)
      if (end === NEED_MORE) {
        this._scanPos = this._end
        const atLeast = this.buffered + this._scanner.pending
        if (atLeast > this.maxValueSize) {
          throw new Error(
            `value of at least ${atLeast} bytes exceeds maxValueSize (${this.maxValueSize})`
          )
        }
        break
      }
      const total = end - this._start
      if (total > this.maxValueSize) {
        throw new Error(
          `value of ${total} bytes exceeds maxValueSize (${this.maxValueSize})`
        )
      }
      values.push(decode(this._buf.subarray(this._start, end)))
      this._start = end
      this._scanPos = end
    }
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
    this._scanPos -= this._start
    this._end = used
    this._start = 0
  }
}

/** @param {{ maxValueSize?: number }} [options] */
export const streamDecoder = options => new StreamDecoder(options)
