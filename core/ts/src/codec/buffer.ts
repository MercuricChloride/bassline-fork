/** A growable run of bytes, appended at the back and dropped from the front. */
export class ByteBuffer {
  #data: Uint8Array
  #length = 0

  constructor(capacity = 64) {
    this.#data = new Uint8Array(capacity)
  }

  get length() {
    return this.#length
  }

  /** The bytes held, as a view; valid until the next write. */
  get bytes() {
    return this.#data.subarray(0, this.#length)
  }

  #reserve(n: number) {
    const need = this.#length + n
    if (need <= this.#data.length) return
    let cap = this.#data.length * 2 || 64
    while (cap < need) cap *= 2
    const data = new Uint8Array(cap)
    data.set(this.bytes)
    this.#data = data
  }

  push(b: number) {
    this.#reserve(1)
    this.#data[this.#length++] = b
  }

  append(bytes: Uint8Array) {
    this.#reserve(bytes.length)
    this.#data.set(bytes, this.#length)
    this.#length += bytes.length
  }

  /** Forget the first `n` bytes, moving the rest to the front. */
  dropFront(n: number) {
    if (n <= 0) return
    this.#data.copyWithin(0, n, this.#length)
    this.#length -= n
  }

  /** A copy of the bytes held, exactly as long as they are. */
  toBytes() {
    return this.#data.slice(0, this.#length)
  }
}
