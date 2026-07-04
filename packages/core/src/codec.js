// @ts-check

// This file acts as the boundary into and out of the value space.
// So it has construction from host data, encoding and decoding from
// canonical bytes, and identity, which is defined by those bytes.
/** @import {Value, Values, ValueKind} from './forms.js' */
import { isValue, assertValue } from './forms.js'

// ================ the header ================
//
// Every value begins with a single header byte:
// [tag:4][mark:1][len:3]
// The first 4 bits carry the type tag. The fifth bit is the actionable
// flag. The last three bits carry the payload length for scalars, and
// must be zero everywhere else.
export const NIL_TAG = 0x1
export const INT_TAG = 0x2
export const STRING_TAG = 0x3
export const SYMBOL_TAG = 0x4
export const BYTES_TAG = 0x5
export const LIST_TAG = 0x6
export const RECORD_TAG = 0x7
export const DICT_TAG = 0x8
export const SET_TAG = 0x9
export const END_BYTE = 0xa0

/** @param {number} b */
export const headerTag = b => b >>> 4
/** @param {number} b */
export const headerMark = b => (b & 0x08) !== 0
/** @param {number} b */
export const headerLen = b => b & 0x07

// The two-byte length form covers 7..254; 255 escapes to a 4-byte
// big-endian length. Anything past ~4.3GB isn't an atom and requires
// a vocabulary for chunking
const MAX_LENGTH = 0xffffffff

/**
 * Freeze an array we own, so a mutation can't silently invalidate a cached CE.
 * @template T
 * @param {T[]} arr
 * @returns {readonly T[]}
 */
function frozen(arr) {
  return Object.freeze(arr)
}

/**
 * A frozen value literal.
 * @template {ValueKind} K
 * @param {K} kind
 * @param {Values[K]['value']} value
 * @param {boolean} actionable
 * @returns {Values[K]}
 */
function mk(kind, value, actionable) {
  return Object.freeze(/** @type {any} */ ({ kind, value, actionable }))
}

// ================ constructors ================

/** @param {boolean} actionable */
export function nil(actionable = false) {
  return mk('nil', null, actionable)
}

/**
 * @param {bigint | number} value
 * @param {boolean} actionable
 */
export function int(value, actionable = false) {
  if (typeof value !== 'number' && typeof value !== 'bigint') {
    throw new TypeError('int expects a BigInt or Number')
  }
  return mk('int', BigInt(value), actionable)
}

/**
 * @param {string} value
 * @param {boolean} actionable
 */
export function string(value, actionable = false) {
  if (typeof value !== 'string') throw new TypeError('string expects a string')
  if (!value.isWellFormed()) throw new Error('string is not well-formed')
  return mk('string', value, actionable)
}

/**
 * @param {string} value
 * @param {boolean} actionable
 */
export function symbol(value, actionable = false) {
  if (typeof value !== 'string') {
    console.error('symbol expects a string, but got:', value)
    throw new TypeError('symbol expects a string')
  }
  if (!value.isWellFormed()) throw new Error('symbol string is not well-formed')
  return mk('symbol', value, actionable)
}

/**
 * @param {Uint8Array} value
 * @param {boolean} actionable
 */
export function bytes(value, actionable = false) {
  if (!(value instanceof Uint8Array))
    throw new TypeError('bytes expects a Uint8Array')
  return mk('bytes', value.slice(), actionable)
}

/**
 * @param {Value[]} items
 * @param {boolean} actionable
 */
export function list(items, actionable = false) {
  if (!Array.isArray(items) || !items.every(isValue)) {
    throw new TypeError('list expects an array of Bassline values')
  }
  return mk('list', /** @type {Value[]} */ (frozen(items.slice())), actionable)
}

/**
 * @param {Value[]} aRecord
 * @param {boolean} actionable
 */
export function record(aRecord, actionable = false) {
  if (!Array.isArray(aRecord) || !aRecord.every(isValue)) {
    throw new TypeError('record expects an array of Bassline values')
  }
  if (aRecord.length === 0) {
    throw new TypeError('record must be a non-empty array of Bassline values')
  }
  return mk(
    'record',
    /** @type {[Value, ...Value[]]} */ (frozen(aRecord.slice())),
    actionable
  )
}

/**
 * @param {Value[]} members
 * @param {boolean} actionable
 */
export function set(members, actionable = false) {
  if (!Array.isArray(members) || !members.every(isValue)) {
    throw new TypeError('set expects an array of Bassline values')
  }
  return mk('set', /** @type {Value[]} */ (dedup(members)), actionable)
}

/**
 * @param {Array<[Value, Value]>} entries
 * @param {boolean} actionable
 */
export function dict(entries, actionable = false) {
  if (
    !Array.isArray(entries) ||
    !entries.every(e => Array.isArray(e) && isValue(e[0]) && isValue(e[1]))
  ) {
    throw new TypeError('dict expects an array of [Value, Value] entries')
  }
  return mk(
    'dict',
    /** @type {Array<[Value, Value]>} */ (dedupEntries(entries)),
    actionable
  )
}

// ================ canonical encoding ================

const ENC = new TextEncoder()
const DEC = new TextDecoder('utf-8', { fatal: true })

/** @type {WeakMap<Value, Uint8Array>} */
const CE_CACHE = new WeakMap()

/**
 * @param {Value} v
 * @returns {Uint8Array}
 */
export function encode(v) {
  /** @type {number[]} */
  const sink = []
  encodeInto(v, sink)
  return Uint8Array.from(sink)
}

/**
 * @param {Value} v
 * @param {number[]} sink
 */
function encodeInto(v, sink) {
  const mark = v.actionable ? 0x08 : 0
  switch (v.kind) {
    case 'nil':
      sink.push((NIL_TAG << 4) | mark)
      return
    case 'int':
      // The payload is the decimal notation itself. Bigint stringification
      // is canonical by construction: no leading zeros, no -0, no +.
      scalar(sink, (INT_TAG << 4) | mark, ENC.encode(v.value.toString()))
      return
    case 'string':
      scalar(sink, (STRING_TAG << 4) | mark, ENC.encode(v.value))
      return
    case 'symbol':
      scalar(sink, (SYMBOL_TAG << 4) | mark, ENC.encode(v.value))
      return
    case 'bytes':
      scalar(sink, (BYTES_TAG << 4) | mark, v.value)
      return
    case 'list':
      sink.push((LIST_TAG << 4) | mark)
      for (const item of v.value) encodeInto(item, sink)
      sink.push(END_BYTE)
      return
    case 'record':
      sink.push((RECORD_TAG << 4) | mark)
      for (const item of v.value) encodeInto(item, sink)
      sink.push(END_BYTE)
      return
    // Note: sets & dicts shouldn't have to dedup — construction already
    // canonicalized. I'm just being slightly paranoid about ordering.
    case 'set':
      sink.push((SET_TAG << 4) | mark)
      for (const member of dedup(v.value)) encodeInto(member, sink)
      sink.push(END_BYTE)
      return
    case 'dict':
      sink.push((DICT_TAG << 4) | mark)
      for (const [key, value] of dedupEntries(v.value)) {
        encodeInto(key, sink)
        encodeInto(value, sink)
      }
      sink.push(END_BYTE)
      return
    default:
      throw new Error('encode: invalid value!')
  }
}

/**
 * Emit a scalar: header with the tiered length, then the payload.
 * @param {number[]} sink
 * @param {number} base the tag and mark bits, length bits clear
 * @param {Uint8Array} payload
 */
function scalar(sink, base, payload) {
  const len = payload.length
  if (len <= 6) {
    sink.push(base | len)
  } else if (len <= 254) {
    sink.push(base | 7, len)
  } else {
    if (len > MAX_LENGTH) throw new Error('payload too large')
    sink.push(base | 7, 255)
    sink.push(
      (len >>> 24) & 0xff,
      (len >>> 16) & 0xff,
      (len >>> 8) & 0xff,
      len & 0xff
    )
  }
  for (const b of payload) sink.push(b)
}

/** @param {Value} v */
function cachedCE(v) {
  let b = CE_CACHE.get(v)
  if (!b) {
    const encoded = encode(v)
    CE_CACHE.set(v, encoded)
    b = encoded
  }
  return b
}

// ================ identity ================

/**
 * @param {Uint8Array} a
 * @param {Uint8Array} b
 */
function bytesEqual(a, b) {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

/**
 * @param {Uint8Array} a
 * @param {Uint8Array} b
 * @returns {number} A negative number if a < b, 0 if a == b, a positive number if a > b
 */
function compareBytes(a, b) {
  const n = Math.min(a.length, b.length)
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) return a[i] - b[i]
  }
  return a.length - b.length
}

/**
 * Total order over values by their CE bytes. This is doesn't keep numeric order
 * @param {Value} a
 * @param {Value} b
 * @returns {number} A negative number if a < b, 0 if a == b, a positive number if a > b
 */
export function cmp(a, b) {
  return compareBytes(cachedCE(a), cachedCE(b))
}

/**
 * Dedups and sorts an array of values by CE
 * @param {Value[]} values
 * @returns {readonly Value[]}
 */
export function dedup(values) {
  const sorted = values.toSorted(cmp)
  const out = []
  for (let i = 0; i < sorted.length; i++) {
    if (i === 0 || cmp(sorted[i - 1], sorted[i]) !== 0) {
      out.push(sorted[i])
    }
  }
  return frozen(out)
}

/**
 * Sorts an array of entries by the key CE
 * This treats keys as LWW
 * @param {Array<[Value, Value]>} entries
 * @returns {ReadonlyArray<[Value, Value]>}
 */
export function dedupEntries(entries) {
  const sorted = entries.toSorted((x, y) => cmp(x[0], y[0]))
  const out = []
  for (let i = 0; i < sorted.length; i++) {
    // only keep an entry if the next one has a different key
    if (i === sorted.length - 1 || cmp(sorted[i][0], sorted[i + 1][0]) !== 0) {
      out.push(sorted[i])
    }
  }
  return frozen(out)
}

/**
 *
 * @param {Value} a
 * @param {Value} b
 * @returns {boolean} True if a and b are equal, false otherwise
 */
export function eq(a, b) {
  assertValue(a)
  assertValue(b)
  if (a === b) return true
  return bytesEqual(cachedCE(a), cachedCE(b))
}

// ================ decoding ================

export const CANONICAL_INT = /^(0|-?[1-9][0-9]*)$/

export class BasslineDecoder {
  /**
   * @param {Uint8Array} bytes
   * @param {{maxDepth?: number, maxLength?: number}} [opts]
   */
  constructor(bytes, { maxDepth = 1024, maxLength = Infinity } = {}) {
    this.bytes = bytes
    this.pos = 0
    this.maxDepth = maxDepth
    this.maxLength = maxLength
  }

  readByte() {
    if (this.pos >= this.bytes.length)
      throw new Error('unexpected end of input')
    return this.bytes[this.pos++]
  }

  /** @param {number} n The number of bytes to read  */
  readBytes(n) {
    if (this.pos + n > this.bytes.length)
      throw new Error('unexpected end of input')
    const b = this.bytes.subarray(this.pos, this.pos + n)
    this.pos += n
    return b
  }

  /**
   * The payload length of a scalar. Each form is mandatory in its range, so
   * every length has exactly one spelling.
   * @param {number} len3 the header's low three bits
   */
  readLength(len3) {
    let n
    if (len3 <= 6) {
      n = len3
    } else {
      const b1 = this.readByte()
      if (b1 < 7) throw new Error('non-minimal length')
      if (b1 < 255) {
        n = b1
      } else {
        n = 0
        for (const byte of this.readBytes(4)) n = n * 256 + byte
        if (n < 255) throw new Error('non-minimal length')
      }
    }
    if (n > this.maxLength)
      throw new Error('payload exceeds the local length limit')
    return n
  }

  /**
   * @param {Uint8Array} payload
   * @param {boolean} mark
   */
  decodeInt(payload, mark) {
    const text = DEC.decode(payload)
    if (!CANONICAL_INT.test(text))
      throw new Error('non-canonical integer: ' + JSON.stringify(text))
    return mk('int', BigInt(text), mark)
  }

  /**
   * @param {number} depth
   * @returns {Value}
   */
  decodeValue(depth = 0) {
    if (depth > this.maxDepth) throw new Error('maximum depth exceeded')
    const b = this.readByte()
    if (b === END_BYTE) throw new Error('END with no open frame')
    const tag = headerTag(b)
    const mark = headerMark(b)
    const len3 = headerLen(b)
    switch (tag) {
      case NIL_TAG:
        if (len3 !== 0) throw new Error('nil carries no payload')
        return mk('nil', null, mark)
      case INT_TAG:
        return this.decodeInt(this.readBytes(this.readLength(len3)), mark)
      case STRING_TAG:
        // fatal UTF-8 decode guarantees well-formedness
        return mk(
          'string',
          DEC.decode(this.readBytes(this.readLength(len3))),
          mark
        )
      case SYMBOL_TAG:
        return mk(
          'symbol',
          DEC.decode(this.readBytes(this.readLength(len3))),
          mark
        )
      case BYTES_TAG:
        // slice: don't alias the input buffer
        return mk('bytes', this.readBytes(this.readLength(len3)).slice(), mark)
      case LIST_TAG:
      case RECORD_TAG:
      case DICT_TAG:
      case SET_TAG:
        if (len3 !== 0) throw new Error('a frame header carries no length')
        return this.decodeFrame(tag, mark, depth + 1)
      default:
        throw new Error('invalid tag 0x' + tag.toString(16))
    }
  }

  /**
   * Children until END, then per-kind validation. Dict keys and set members
   * are checked for strict CE order by comparing their raw byte spans, so
   * construction here trusts the validation and skips re-canonicalizing.
   * @param {number} tag
   * @param {boolean} mark
   * @param {number} depth
   * @returns {Value}
   */
  decodeFrame(tag, mark, depth) {
    /** @type {Value[]} */
    const items = []
    /** @type {Array<[number, number]>} */
    const spans = []
    while (true) {
      if (this.pos >= this.bytes.length) throw new Error('unterminated frame')
      if (this.bytes[this.pos] === END_BYTE) {
        this.pos++
        break
      }
      const start = this.pos
      items.push(this.decodeValue(depth))
      spans.push([start, this.pos])
    }
    switch (tag) {
      case LIST_TAG:
        return mk('list', /** @type {Value[]} */ (frozen(items)), mark)
      case RECORD_TAG:
        if (items.length === 0) throw new Error('record missing head')
        return mk(
          'record',
          /** @type {[Value, ...Value[]]} */ (frozen(items)),
          mark
        )
      case SET_TAG:
        this.assertAscending(spans, 'set member')
        return mk('set', /** @type {Value[]} */ (frozen(items)), mark)
      case DICT_TAG: {
        if (items.length % 2 !== 0) throw new Error('dict key missing value')
        this.assertAscending(
          spans.filter((_, i) => i % 2 === 0),
          'dictionary key'
        )
        /** @type {Array<[Value, Value]>} */
        const entries = []
        for (let i = 0; i < items.length; i += 2) {
          entries.push([items[i], items[i + 1]])
        }
        return mk(
          'dict',
          /** @type {Array<[Value, Value]>} */ (frozen(entries)),
          mark
        )
      }
      default:
        throw new Error('invalid frame tag 0x' + tag.toString(16))
    }
  }

  /**
   * @param {Array<[number, number]>} spans
   * @param {string} what
   */
  assertAscending(spans, what) {
    for (let i = 1; i < spans.length; i++) {
      const prev = this.bytes.subarray(spans[i - 1][0], spans[i - 1][1])
      const cur = this.bytes.subarray(spans[i][0], spans[i][1])
      const c = compareBytes(prev, cur)
      if (c > 0) throw new Error(what + 's out of order')
      if (c === 0) throw new Error('duplicate ' + what)
    }
  }
}

/**
 * Decode exactly one value; trailing bytes are an error.
 * @param {Uint8Array} bytes
 * @param {{maxDepth?: number, maxLength?: number}} [opts]
 */
export function decode(bytes, opts) {
  const dec = new BasslineDecoder(bytes, opts)
  const val = dec.decodeValue()
  if (dec.pos !== bytes.length) throw new Error('extra bytes at end of input')
  return val
}

/**
 * Decode the sequence of values in the input (a document).
 * @param {Uint8Array} bytes
 * @param {{maxDepth?: number, maxLength?: number}} [opts]
 */
export function decodeAll(bytes, opts) {
  const dec = new BasslineDecoder(bytes, opts)
  const values = []
  while (dec.pos < bytes.length) {
    values.push(dec.decodeValue())
  }
  return values
}
