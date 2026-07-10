//@ts-check
// Find value boundaries in a bassline binary stream.
//
// The encoding is self-delimiting but not length-prefixed: scalars announce
// their payload size in a tiered header, while frames run until their closing
// END byte. A value's extent is therefore discovered by walking it, not read
// from its header. ValueScanner does that walk incrementally: feed it windows
// of the stream and it consumes bytes — skipping scalar payloads, counting
// frame opens and closes — until exactly one whole value has passed. It
// touches each byte at most once and holds O(1) state, so chunking never
// causes rescans and nothing is materialized.
//
// The scanner only frames; validity (length minimality, UTF-8, canonical
// integers, dict/set order, depth policy) belongs to core `decode()` on the
// sliced value. It does reject bytes that cannot occur where they stand,
// since a byte stream can't resync after a framing error.

import { TAGS, END_BYTE, headerTag, headerLen } from '@bassline/core/data'

/** Returned when the window ends before the value does. */
export const NEED_MORE = Symbol('NEED_MORE')

// Scanner states: what the next unread byte is expected to be.
const HEADER = 0 // a value header, or END closing an open frame
const LEN1 = 1 // the one-byte medium length, or the 0xff escape to LEN4
const LEN4 = 2 // one of the four big-endian large-length bytes
const PAYLOAD = 3 // scalar payload bytes, `skip` of them still owed

export class ValueScanner {
  constructor() {
    this.depth = 0 // open, not-yet-closed frames
    this.skip = 0 // announced payload bytes not yet consumed
    this.state = HEADER
    this.len4 = 0 // big-endian accumulator for LEN4
    this.len4n = 0 // LEN4 bytes still owed
  }

  /**
   * Payload bytes announced by a scalar header but not yet seen. Added to the
   * bytes already fed, this lower-bounds the value's final size, so a caller
   * can refuse an over-large value before buffering its body.
   */
  get pending() {
    return this.skip
  }

  /**
   * Consume `bytes[from, to)` until one whole value has been seen. Returns
   * the offset just past the value's last byte, or {@link NEED_MORE} after
   * consuming the entire window; feed the next window to continue. Completing
   * a value leaves the scanner pristine for the next one. Throws on a byte
   * that cannot occur where it stands, after which the scanner is unusable.
   * @param {Uint8Array} bytes
   * @param {number} [from]
   * @param {number} [to]
   * @returns {number | typeof NEED_MORE}
   */
  feed(bytes, from = 0, to = bytes.length) {
    let pos = from
    while (true) {
      if (this.state === PAYLOAD) {
        const take = Math.min(this.skip, to - pos)
        pos += take
        this.skip -= take
        if (this.skip > 0) return NEED_MORE
        this.state = HEADER
        if (this.depth === 0) return pos
      }
      if (pos >= to) return NEED_MORE
      const b = bytes[pos++]
      switch (this.state) {
        case LEN1:
          if (b === 0xff) {
            this.state = LEN4
            this.len4 = 0
            this.len4n = 4
          } else {
            this.skip = b
            this.state = PAYLOAD
          }
          break
        case LEN4:
          this.len4 = this.len4 * 256 + b
          if (--this.len4n === 0) {
            this.skip = this.len4
            this.state = PAYLOAD
          }
          break
        default: {
          if (b === END_BYTE) {
            if (this.depth === 0) throw new Error('END with no open frame')
            this.depth--
            if (this.depth === 0) return pos
            break
          }
          const tag = headerTag(b)
          const len3 = headerLen(b)
          switch (tag) {
            case TAGS.nil:
              if (len3 !== 0) throw new Error('nil carries no payload')
              if (this.depth === 0) return pos
              break
            case TAGS.int:
            case TAGS.string:
            case TAGS.symbol:
            case TAGS.bytes:
              if (len3 < 7) {
                this.skip = len3
                this.state = PAYLOAD
              } else {
                this.state = LEN1
              }
              break
            case TAGS.list:
            case TAGS.record:
            case TAGS.dict:
            case TAGS.set:
              if (len3 !== 0)
                throw new Error('a frame header carries no length')
              this.depth++
              break
            default:
              throw new Error(
                'cannot frame value: bad header byte 0x' +
                  b.toString(16).padStart(2, '0')
              )
          }
        }
      }
    }
  }
}

/**
 * Size in bytes of the first complete value at `offset`, or {@link NEED_MORE}
 * when the window ends before the value does. A fresh walk each call — for
 * incremental use across chunks, hold a {@link ValueScanner} instead.
 * @param {Uint8Array} bytes
 * @param {number} [offset]
 * @returns {number | typeof NEED_MORE}
 */
export function scanValue(bytes, offset = 0) {
  const end = new ValueScanner().feed(bytes, offset)
  return end === NEED_MORE ? NEED_MORE : end - offset
}
