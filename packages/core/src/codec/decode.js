// @ts-check

// The byte-backed reading. A ValueView borrows the buffer: its identity is
// its CE span, its children are lazy, and validation is deferred and memoized
// per node. The Decoder is resumable — feed it byte chunks and it hands back
// whole values as they complete, staying pending across a split.

import {
  CodecError,
  MAX_DEPTH,
  MAX_VALUE_BYTES,
  isFrameKind,
} from './header.js'
import { compareBytes, isCanonicalInt, isWellFormedUtf8 } from './payload.js'
import { ByteBuffer, ByteCursor, Starved } from './buffer.js'
import { walkEvents } from './events.js'

export { CodecError }

/**
 * A borrowed view's freshness check: the {@link ByteBuffer} it points into and
 * that buffer's generation at the moment the view was made. When the buffer
 * later compacts (shifting bytes in place), the generation moves and the view
 * knows it is stale.
 * @typedef {{ buffer: ByteBuffer, gen: number }} Guard
 */

/**
 * The offset just past the value beginning at `at`. Throws {@link Starved}
 * when the buffer ends first, {@link CodecError} on a structural fault.
 * @param {Uint8Array} buf
 * @param {number} at
 * @param {{ maxValueBytes?: number }} [opts]
 */
export function valueEnd(buf, at, opts) {
  const cur = new ByteCursor(buf, at)
  let depth = 0
  for (const ev of walkEvents(cur, opts)) {
    if (ev.t === 'open') {
      depth++
    } else if (ev.t === 'close') {
      if (depth === 0) throw new CodecError('END with no open frame')
      if (--depth === 0) return cur.pos
    } else if (depth === 0) {
      return cur.pos
    }
  }
  throw new Starved()
}

export class ValueView {
  #buf
  #at
  #end
  #kind
  #mark
  #payloadAt = -1
  #payloadLen = -1
  /** @type {ValueView[] | null} */
  #children = null
  #validated = false
  /** @type {Guard | undefined} */
  #guard

  /**
   * @param {Uint8Array} buf
   * @param {number} at offset of the header byte
   * @param {number} [end] offset just past the last byte; computed if omitted
   * @param {Guard} [guard] set when the view borrows a compacting decoder buffer
   */
  constructor(buf, at, end, guard) {
    this.#buf = buf
    this.#at = at
    this.#guard = guard
    const first = walkEvents(new ByteCursor(buf, at)).next().value
    if (!first || first.t === 'close') throw new CodecError('not a value')
    this.#mark = first.mark
    if (first.t === 'nil') {
      this.#kind = 'nil'
    } else if (first.t === 'atom') {
      this.#kind = first.kind
      this.#payloadAt = first.payloadAt
      this.#payloadLen = first.payloadLen
    } else {
      this.#kind = first.kind
    }
    this.#end = end ?? valueEnd(buf, at)
  }

  get kind() {
    return this.#kind
  }
  get mark() {
    return this.#mark
  }

  /**
   * Refuse a read whose backing bytes the decoder has since compacted away.
   */
  #assertFresh() {
    if (this.#guard && this.#guard.buffer.generation !== this.#guard.gen) {
      throw new CodecError(
        'ValueView is stale — the decoder compacted past the bytes it borrowed'
      )
    }
  }

  /** This value's CE bytes — a view into the shared buffer. */
  slice() {
    this.#assertFresh()
    return this.#buf.subarray(this.#at, this.#end)
  }

  /** A scalar's payload bytes — a view into the shared buffer. */
  get payloadBytes() {
    this.#assertFresh()
    if (this.#payloadAt < 0) throw new Error(this.#kind + ' has no payload')
    return this.#buf.subarray(
      this.#payloadAt,
      this.#payloadAt + this.#payloadLen
    )
  }

  /**
   * Child views in document order. For a dict this is the flat
   * key, value, key, value, ... sequence. Lazy and memoized.
   * @returns {ValueView[]}
   */
  children() {
    this.#assertFresh()
    if (this.#children === null) this.#children = this.#walkChildren()
    return this.#children
  }

  /** @returns {ValueView[]} */
  #walkChildren() {
    if (!isFrameKind(this.#kind)) return []
    /** @type {ValueView[]} */
    const out = []
    const cur = new ByteCursor(this.#buf, this.#at + 1)
    let depth = 0
    let start = -1
    for (const ev of walkEvents(cur)) {
      if (depth === 0 && ev.t !== 'close') start = ev.at
      if (ev.t === 'open') {
        depth++
      } else if (ev.t === 'close') {
        if (depth === 0) break // our own closing END
        if (--depth === 0) {
          out.push(new ValueView(this.#buf, start, cur.pos, this.#guard))
        }
      } else if (depth === 0) {
        out.push(new ValueView(this.#buf, start, cur.pos, this.#guard))
      }
    }
    return out
  }

  /**
   * Check the deferred rules for this node and its subtree: canonical integer
   * spelling, well-formed UTF-8, a non-empty record, strictly ascending and
   * unique dict keys / set members. Memoized.
   */
  validate() {
    if (this.#validated) return
    switch (this.#kind) {
      case 'nil':
      case 'bytes':
        break
      case 'number':
        if (!isCanonicalInt(this.payloadBytes)) {
          throw new CodecError('non-canonical integer')
        }
        break
      case 'text':
      case 'symbol':
        if (!isWellFormedUtf8(this.payloadBytes)) {
          throw new CodecError('ill-formed UTF-8 in ' + this.#kind)
        }
        break
      case 'list':
        for (const c of this.children()) c.validate()
        break
      case 'record': {
        const cs = this.children()
        if (cs.length === 0) throw new CodecError('record has no head')
        for (const c of cs) c.validate()
        break
      }
      case 'set': {
        const cs = this.children()
        for (let i = 0; i < cs.length; i++) {
          cs[i].validate()
          if (i > 0) this.#assertAscending(cs[i - 1], cs[i], 'set member')
        }
        break
      }
      case 'dict': {
        const cs = this.children()
        if (cs.length % 2 !== 0)
          throw new CodecError('dict key without a value')
        for (let i = 0; i < cs.length; i += 2) {
          cs[i].validate()
          cs[i + 1].validate()
          if (i > 0) this.#assertAscending(cs[i - 2], cs[i], 'dict key')
        }
        break
      }
    }
    this.#validated = true
  }

  /**
   * @param {ValueView} a
   * @param {ValueView} b
   * @param {string} what
   */
  #assertAscending(a, b, what) {
    const c = compareBytes(a.slice(), b.slice())
    if (c > 0) throw new CodecError(what + 's out of order')
    if (c === 0) throw new CodecError('duplicate ' + what)
  }

  /** @param {ValueView} o */
  compare(o) {
    return compareBytes(this.slice(), o.slice())
  }
  /** @param {ValueView} o */
  equals(o) {
    return this.compare(o) === 0
  }
}

export class Decoder {
  #buffer = new ByteBuffer()
  #cursor = new ByteCursor(this.#buffer)
  #depth = 0
  #valueStart = -1
  #starved = false
  #maxDepth
  #maxValueBytes
  #walkOpts

  /** @param {{ maxDepth?: number, maxValueBytes?: number }} [opts] */
  constructor(opts = {}) {
    this.#maxDepth = opts.maxDepth ?? MAX_DEPTH
    this.#maxValueBytes = opts.maxValueBytes ?? MAX_VALUE_BYTES
    this.#walkOpts = { maxValueBytes: this.#maxValueBytes }
  }

  /** Whether a value is mid-parse: an open frame, or a starved scalar. */
  get pending() {
    return this.#depth > 0 || this.#starved
  }

  /** Bytes held and not yet drained into a value. */
  get buffered() {
    const from = this.#valueStart < 0 ? this.#cursor.pos : this.#valueStart
    return this.#buffer.length - from
  }

  /**
   * Append `chunk` and return every value now fully buffered.
   * @param {Uint8Array} chunk
   * @param {{ validate?: boolean }} [pushOpts]
   * @returns {ValueView[]}
   */
  push(chunk, pushOpts = {}) {
    const validate = pushOpts.validate ?? true
    this.#buffer.append(chunk)
    this.#starved = false

    /** @type {ValueView[]} */
    const out = []
    /** @type {Guard} */
    const guard = { buffer: this.#buffer, gen: this.#buffer.generation }
    try {
      for (const ev of walkEvents(this.#cursor, this.#walkOpts)) {
        if (this.#depth === 0) this.#valueStart = ev.at
        if (ev.t === 'open') {
          if (++this.#depth > this.#maxDepth) {
            throw new CodecError('maximum depth exceeded')
          }
        } else if (ev.t === 'close') {
          if (this.#depth === 0) {
            throw new CodecError('END with no open frame')
          }
          this.#depth--
        }
        if (this.#depth === 0) {
          const view = new ValueView(
            this.#cursor.bytes,
            this.#valueStart,
            this.#cursor.pos,
            guard
          )
          if (validate) view.validate()
          out.push(view)
          this.#valueStart = -1
        }
      }
    } catch (e) {
      if (e instanceof Starved) this.#starved = true
      else throw e
    }
    // whether the walk ended by starvation or by an unclosed frame at the end
    // of the buffer, cap what one value is allowed to hold
    if (this.#depth > 0 && this.#valueStart >= 0) {
      if (this.#buffer.length - this.#valueStart > this.#maxValueBytes) {
        throw new CodecError('unclosed frame exceeds the value-size limit')
      }
    }
    return out
  }

  /**
   * Drop the bytes already drained, so a long stream stays bounded. Safe only
   * between full drains and while no frame is open: it shifts the buffer that
   * prior ValueViews point into, so any view from an earlier drain is stale.
   */
  compact() {
    if (this.#depth > 0 || this.#cursor.pos === 0) return
    this.#buffer.dropFront(this.#cursor.pos)
    this.#cursor.pos = 0
    this.#valueStart = -1
  }
}
