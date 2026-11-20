// @ts-check

// A growable byte store and a read cursor over one, mirroring Nim's
// core/buffer.nim. A Uint8Array is fixed-size, so appending means writing into
// spare capacity and only making a larger store — copying the live bytes into
// it — when that runs out. With capacity doubling that copy happens O(log n)
// times over a stream, not once per append.

/** Thrown by a walk when the buffer ends before the current value does. */
export class Starved extends Error {
  /** @param {number} [owed] payload bytes already known to be outstanding */
  constructor(owed = 0) {
    super('starved')
    this.owed = owed
  }
}

export class ByteBuffer {
  /** backing store; the live bytes are `[0, #len)`, the rest is spare */
  #store = new Uint8Array(0)
  #len = 0
  /** bumped by {@link dropFront} — the one op that moves live bytes in place */
  #generation = 0

  /** @param {number} [capacity] bytes to pre-allocate */
  constructor(capacity = 0) {
    if (capacity > 0) this.#store = new Uint8Array(capacity)
  }

  /** How many live bytes are held. */
  get length() {
    return this.#len
  }

  /**
   * A counter that changes only when {@link dropFront} shifts the live bytes.
   * A borrower that captured a byte view can compare this to detect that its
   * view is now stale.
   */
  get generation() {
    return this.#generation
  }

  /**
   * The live bytes as a view into the store. Valid only until the next
   * {@link append} or {@link dropFront}.
   */
  bytes() {
    return this.#store.subarray(0, this.#len)
  }

  /**
   * Append one byte, growing the store if needed.
   * @param {number} byte
   */
  push(byte) {
    this.#reserve(1)
    this.#store[this.#len++] = byte
  }

  /**
   * Append `chunk`, growing the store if needed. Amortized O(1) per byte.
   * A grow copies the live bytes into a new store but never mutates the old
   * one, so a view taken beforehand stays valid — only {@link dropFront} does.
   * @param {Uint8Array} chunk
   */
  append(chunk) {
    this.#reserve(chunk.length)
    this.#store.set(chunk, this.#len)
    this.#len += chunk.length
  }

  /**
   * Drop the first `n` live bytes, shifting the rest to the front. This moves
   * the bytes in place, so any view taken from {@link bytes} beforehand is
   * stale afterwards — hence the {@link generation} bump.
   * @param {number} n
   */
  dropFront(n) {
    if (n <= 0) return
    n = Math.min(n, this.#len)
    this.#store.copyWithin(0, n, this.#len)
    this.#len -= n
    this.#generation++
  }

  /**
   * Grow the store so `extra` more bytes fit past `#len`.
   * @param {number} extra
   */
  #reserve(extra) {
    if (this.#store.length - this.#len >= extra) return
    let cap = Math.max(this.#store.length * 2, 64)
    while (cap - this.#len < extra) cap *= 2
    const grown = new Uint8Array(cap)
    grown.set(this.#store.subarray(0, this.#len), 0)
    this.#store = grown
  }
}

/**
 * A read position over a byte source — a {@link ByteBuffer} (whose live bytes
 * grow between reads) or a fixed Uint8Array. `pos` advances as a walk consumes.
 */
export class ByteCursor {
  /** @type {ByteBuffer | Uint8Array} */
  #src

  /**
   * @param {ByteBuffer | Uint8Array} src
   * @param {number} [pos]
   */
  constructor(src, pos = 0) {
    this.#src = src
    this.pos = pos
  }

  /** The current bytes. Re-read after the source has grown. */
  get bytes() {
    return this.#src instanceof ByteBuffer ? this.#src.bytes() : this.#src
  }

  get remaining() {
    return this.bytes.length - this.pos
  }
}
