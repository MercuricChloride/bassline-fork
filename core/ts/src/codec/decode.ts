import type { Factory, FrameKind, Value } from '../types.ts'
import { ByteBuffer } from './buffer.ts'
import {
  CodecError,
  compareEncoded,
  decodeUtf8,
  END,
  Incomplete,
  integer,
  MAX_DEPTH,
  MAX_VALUE_BYTES,
  readHeader,
  validate,
} from './util.ts'

export type DecoderOptions = {
  /** How deep frames may nest. */
  maxDepth?: number
  /** How many CE bytes one value may run to, counted from its header. */
  maxValueBytes?: number
}

/**
 * A frame still open. Offsets are absolute: counted from the first byte the
 * decoder was ever given, so dropping bytes from the front moves nothing.
 */
type Open = {
  kind: FrameKind
  mark: boolean
  start: number
  items: Value[]
  /** Where the last set member or dict key began and ended, to order the next by. */
  last: [number, number] | null
}

/**
 * A resumable decoder, building values with the factory it is given. `add` bytes as they arrive, in pieces of any size,
 * and pull `values()` for every value they now hold whole. Running out
 * inside a value breaks no rule; the decoder waits there for more.
 *
 * Every rule is checked as the bytes arrive, so a refusal names the first
 * fault in byte order. A decoder that refused stays refused.
 */
export class Decoder {
  #buf = new ByteBuffer()
  /** The absolute offset of the buffer's first byte. */
  #base = 0
  /** The next byte to read, as an index into the buffer. */
  #pos = 0
  #stack: Open[] = []
  #failed: CodecError | null = null
  #final = false
  readonly factory: Factory
  readonly maxDepth: number
  readonly maxValueBytes: number

  constructor(factory: Factory, opts: DecoderOptions = {}) {
    this.factory = factory
    this.maxDepth = opts.maxDepth ?? MAX_DEPTH
    this.maxValueBytes = opts.maxValueBytes ?? MAX_VALUE_BYTES
  }

  /** Whether bytes are held toward a value not yet whole. */
  get pending() {
    return this.#stack.length > 0 || this.#pos < this.#buf.length
  }

  /** The refusal this decoder stopped at, if it has. */
  get failed() {
    return this.#failed
  }

  /** Take more bytes. Bytes already landed as values are let go. */
  add(chunk: Uint8Array) {
    if (this.#failed) throw this.#failed
    if (this.#final) throw new Error('bytes added after finish')
    const keep =
      this.#stack.length > 0 ? this.#stack[0]!.start - this.#base : this.#pos
    this.#buf.dropFront(keep)
    this.#base += keep
    this.#pos -= keep
    this.#buf.append(chunk)
  }

  /**
   * Every value the bytes held now complete, one per pull, each landed as
   * the pull reaches it: stopping early leaves the rest for a later pull.
   * Throws a CodecError at a fault, after the values before it, and once
   * finished, Incomplete if the input ends inside a value.
   */
  *values(): Generator<Value> {
    for (;;) {
      if (this.#failed) throw this.#failed
      let v: Value | undefined
      try {
        v = this.#next()
      } catch (e) {
        if (e instanceof CodecError) this.#failed = e
        throw e
      }
      if (v === undefined) {
        if (this.#final && this.pending)
          throw new Incomplete('the input ends inside a value')
        return
      }
      yield v
    }
  }

  /** No more bytes are coming. Pull `values()` for what is left. */
  finish() {
    this.#final = true
  }

  /** Read until a top-level value is whole, or the bytes run out. */
  #next(): Value | undefined {
    const buf = this.#buf.bytes
    while (this.#pos < buf.length) {
      const at = this.#pos
      const b = buf[at]!
      let landed: Value | undefined

      if (b === END && this.#stack.length > 0) {
        this.#pos = at + 1
        this.#bound(this.#pos)
        landed = this.#close()
      } else {
        const h = readHeader(b)
        switch (h.kind) {
          case 'list':
          case 'record':
          case 'dict':
          case 'set':
            if (this.#stack.length >= this.maxDepth) {
              throw new CodecError(
                'max-depth',
                `frames nest past ${this.maxDepth}`
              )
            }
            this.#stack.push({
              kind: h.kind,
              mark: h.mark,
              start: this.#base + at,
              items: [],
              last: null,
            })
            this.#pos = at + 1
            this.#bound(this.#pos)
            break
          case 'nil':
            this.#bound(at + 1)
            this.#pos = at + 1
            landed = this.#land(this.factory.nil(h.mark), at)
            break
          default: {
            // a scalar: its length, in the smallest form, then its payload
            const rest = buf.length - at
            let len = h.lenBits
            let skip = 1
            if (len === 7) {
              if (rest < 2) return undefined
              len = buf[at + 1]!
              skip = 2
              if (len < 7) throw new CodecError('non-minimal-length')
              if (len === 255) {
                if (rest < 6) return undefined
                len = new DataView(
                  buf.buffer,
                  buf.byteOffset + at + 2,
                  4
                ).getUint32(0)
                skip = 6
                if (len < 255) throw new CodecError('non-minimal-length')
              }
            }
            this.#bound(at + skip + len)
            if (rest < skip + len) return undefined
            const p = buf.subarray(at + skip, at + skip + len)
            this.#pos = at + skip + len
            landed = this.#land(scalar(this.factory, h.kind, h.mark, p), at)
          }
        }
      }
      if (landed !== undefined) return landed
    }
    return undefined
  }

  /** Refuse a value that runs past the size cap once `end` is known to be in it. */
  #bound(end: number) {
    const start =
      this.#stack.length > 0 ? this.#stack[0]!.start - this.#base : this.#pos
    if (end - start > this.maxValueBytes) {
      throw new CodecError(
        'max-value-bytes',
        `a value runs past ${this.maxValueBytes} bytes`
      )
    }
  }

  /** The frame on top is closed: build it and land it in its parent. */
  #close(): Value | undefined {
    const f = this.#stack.pop()!
    const make = this.factory
    let v: Value
    switch (f.kind) {
      case 'list':
        v = make.list(f.items, f.mark)
        break
      case 'record':
        if (f.items.length === 0) throw new CodecError('empty-record')
        v = make.record(f.items, f.mark)
        break
      case 'set':
        v = make.set(f.items, f.mark)
        break
      case 'dict': {
        if (f.items.length % 2 !== 0) throw new CodecError('stranded-key')
        const entries: [Value, Value][] = []
        for (let i = 0; i < f.items.length; i += 2) {
          entries.push([f.items[i]!, f.items[i + 1]!])
        }
        v = make.dict(entries, f.mark)
        break
      }
    }
    return this.#land(v, f.start - this.#base)
  }

  /**
   * A value whose bytes began at `at` and end at the read position is whole.
   * At the top level it is answered; in a frame it joins the frame, a set
   * member or dict key only after the last by its CE bytes.
   */
  #land(v: Value, at: number): Value | undefined {
    const f = this.#stack.at(-1)
    if (f === undefined) return v
    if (f.kind === 'set' || (f.kind === 'dict' && f.items.length % 2 === 0)) {
      const start = this.#base + at
      const end = this.#base + this.#pos
      if (f.last !== null) {
        const buf = this.#buf.bytes
        const c = compareEncoded(
          buf.subarray(f.last[0] - this.#base, f.last[1] - this.#base),
          buf.subarray(at, this.#pos)
        )
        if (c === 0) throw new CodecError('duplicate')
        if (c > 0) throw new CodecError('out-of-order')
      }
      f.last = [start, end]
    }
    f.items.push(v)
    return undefined
  }
}

function scalar(
  make: Factory,
  kind: 'number' | 'text' | 'symbol' | 'bytes',
  mark: boolean,
  p: Uint8Array
): Value {
  switch (kind) {
    case 'number':
      if (!validate.number(p)) throw new CodecError('bad-integer')
      return make.number(integer(decodeUtf8(p)), mark)
    case 'text':
    case 'symbol': {
      let s: string
      try {
        s = decodeUtf8(p)
      } catch {
        throw new CodecError('bad-utf8', `ill-formed UTF-8 in a ${kind}`)
      }
      return kind === 'text' ? make.text(s, mark) : make.sym(s, mark)
    }
    case 'bytes':
      return make.bytes(p.slice(), mark)
  }
}

/** Every value in a bare concatenation of CE, given in total. */
export function decodeAll(
  factory: Factory,
  bytes: Uint8Array,
  opts?: DecoderOptions
): Value[] {
  const d = new Decoder(factory, opts)
  d.add(bytes)
  d.finish()
  return [...d.values()]
}

/** Exactly one value, given in total. */
export function decode(
  factory: Factory,
  bytes: Uint8Array,
  opts?: DecoderOptions
): Value {
  const d = new Decoder(factory, opts)
  d.add(bytes)
  d.finish()
  const values = d.values()
  const first = values.next()
  if (first.done) throw new CodecError('no-value', 'no value')
  if (d.pending) {
    // bytes that have begun a second value are refused however they end,
    // by a rule they break first if they break one
    try {
      for (const _ of values);
    } catch (e) {
      if (!(e instanceof Incomplete)) throw e
    }
    throw new CodecError('several-values', 'more than one value')
  }
  return first.value
}
