// @ts-check

export const fresh = /** @constant */ {
  /** @param {boolean} actionable */
  nil(actionable = false) {
    return new BasslineNil(null, actionable)
  },
  /**
   * @param {boolean} value
   * @param {boolean} actionable
   */
  bool(value, actionable = false) {
    if (typeof value !== 'boolean')
      throw new TypeError('bool expects a Boolean')
    return new BasslineBool(value, actionable)
  },
  /**
   * @param {bigint | number} value
   * @param {boolean} actionable
   */
  int(value, actionable = false) {
    if (typeof value === 'number') {
      return new BasslineInt(BigInt(value), actionable)
    } else if (typeof value === 'bigint') {
      return new BasslineInt(value, actionable)
    } else {
      throw new TypeError('int expects a BigInt or Number')
    }
  },
  /**
   * @param {number} value
   * @param {boolean} actionable
   */
  float(value, actionable = false) {
    if (typeof value !== 'number') throw new TypeError('float expects a Number')
    if (Number.isNaN(value)) {
      return new BasslineFloat(NaN, actionable)
    } else {
      return new BasslineFloat(value, actionable)
    }
  },

  /**
   * @param {string} value
   * @param {boolean} actionable
   */
  string(value, actionable = false) {
    if (typeof value !== 'string')
      throw new TypeError('string expects a string')
    if (!value.isWellFormed()) throw new Error('string is not well-formed')
    return new BasslineString(value, actionable)
  },

  /**
   * @param {string} value
   * @param {boolean} actionable
   */
  symbol(value, actionable = false) {
    if (typeof value !== 'string') {
      console.error('symbol expects a string, but got:', value)
      throw new TypeError('symbol expects a string')
    }
    if (!value.isWellFormed())
      throw new Error('symbol string is not well-formed')
    return new BasslineSymbol(value, actionable)
  },
  /**
   * @param {Uint8Array} value
   * @param {boolean} actionable
   */
  bytes(value, actionable = false) {
    if (!(value instanceof Uint8Array))
      throw new TypeError('bytes expects a Uint8Array')
    return new BasslineBytes(value.slice(), actionable)
  },

  /**
   * @param {Value[]} items
   * @param {boolean} actionable
   */
  list(items, actionable = false) {
    if (!Array.isArray(items) || !items.every(isValue)) {
      throw new TypeError('list expects an array of Bassline values')
    }
    return new BasslineList(items.slice(), actionable)
  },

  /**
   * @param {Value[]} aRecord
   * @param {boolean} actionable
   */
  record(aRecord, actionable = false) {
    if (!Array.isArray(aRecord) || !aRecord.every(isValue)) {
      throw new TypeError('record expects an array of Bassline values')
    }
    if (aRecord.length === 0) {
      throw new TypeError('record must be a non-empty array of Bassline values')
    }
    return new BasslineRecord(aRecord.slice(), actionable)
  },
  /**
   * @param {Value[]} members
   * @param {boolean} actionable
   */
  set(members, actionable = false) {
    /** @type {Map<string, Value>} */
    const value = new Map()
    for (const m of members) {
      if (!isValue(m))
        throw new TypeError('set member must be a Bassline value')
      const key = ceKey(m)
      value.set(key, m)
    }
    return new BasslineSet(value, actionable)
  },
  /**
   * @param {Array<[Value, Value]>} entries
   * @param {boolean} actionable
   */
  dict(entries, actionable = false) {
    /** @type {Map<string, [Value, Value]>} */
    const values = new Map()
    for (const [k, v] of entries) {
      if (!isValue(k) || !isValue(v))
        throw new TypeError('dict entry must be [Value, Value]')
      const keyCe = ceKey(k)
      values.set(keyCe, [k, v])
    }
    return new BasslineDict(values, actionable)
  },
}

// ================ Bassline Value Types ================

/**
 * @template T
 * @template {keyof typeof fresh} [K=ValueKind]
 */
class ValueBase {
  /**
   * @param {T} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    /** @private */
    this._actionable = actionable
    /** @protected */
    this._value = value
  }

  get actionable() {
    return this._actionable
  }

  get value() {
    return this._value
  }

  /** @returns {K} */
  get kind() {
    throw new Error('kind getter must be implemented by subclasses')
  }

  /** @returns {typeof fresh[typeof this['kind']]} */
  get fresh() {
    return fresh[this.kind]
  }

  encode() {
    if (isValue(this)) {
      return encode(this)
    }
    throw new Error('encode must be called on a Bassline value')
  }

  ceKey() {
    if (isValue(this)) {
      return ceKey(this)
    }
    throw new Error('ceKey must be called on a Bassline value')
  }

  /** @param {Value} other */
  eq(other) {
    if (isValue(this)) {
      return eq(this, other)
    }
    throw new Error('eq must be called on a Bassline value')
  }

  /**
   * Creates a shallow copy of this value.
   * @param {boolean} [actionable] Whether the copied value should be actionable.
   * @returns {Value} A shallow copy of this value.
   */
  copy(actionable = this.actionable) {
    const clone = Object.create(Object.getPrototypeOf(this))
    clone._value = this._value
    clone._actionable = actionable
    return clone
  }
}

/** @augments {ValueBase<null>} */
export class BasslineNil extends ValueBase {
  copy(actionable = this.actionable) {
    return fresh.nil(actionable)
  }
  /** @returns {'nil'} */
  get kind() {
    return 'nil'
  }
}

/** @augments {ValueBase<boolean>} */
export class BasslineBool extends ValueBase {
  /** @returns {'bool'}*/
  get kind() {
    return 'bool'
  }
}

/** @augments {ValueBase<bigint>} */
export class BasslineInt extends ValueBase {
  /** @returns {'int'}*/
  get kind() {
    return 'int'
  }
}

/** @augments {ValueBase<number>} */
export class BasslineFloat extends ValueBase {
  /** @returns {'float'}*/
  get kind() {
    return 'float'
  }
}

/** @augments {ValueBase<string>} */
export class BasslineString extends ValueBase {
  /** @returns {'string'}*/
  get kind() {
    return 'string'
  }
}

/** @augments {ValueBase<string>} */
export class BasslineSymbol extends ValueBase {
  /** @returns {'symbol'}*/
  get kind() {
    return 'symbol'
  }
}

/** @augments {ValueBase<Uint8Array>} */
export class BasslineBytes extends ValueBase {
  get value() {
    return this._value.slice()
  }
  /** @returns {'bytes'}*/
  get kind() {
    return 'bytes'
  }
}

/**
 * @augments {ValueBase<Value[], 'list' | 'record'>}
 */
class SeqBase extends ValueBase {
  get value() {
    return this._value.slice()
  }
  get length() {
    return this._value.length
  }
  /**
   * @param {number} start
   * @param {number} end
   */
  slice(start, end) {
    const slice = this._value.slice(start, end)
    return this.fresh(slice, this.actionable)
  }
  /**
   * @param {(item: Value, index: number, array: Value[]) => Value} callback
   */
  map(callback) {
    const mapped = this._value.map(callback)
    return this.fresh(mapped, this.actionable)
  }
  /**
   * @param {(item: Value, index: number, array: Value[]) => boolean} callback
   */
  filter(callback) {
    const filtered = this._value.filter(callback)
    return this.fresh(filtered, this.actionable)
  }
  /**
   * @param {number} index
   */
  at(index) {
    return this._value.at(index)
  }
  /**
   * @param {number} index
   * @param {Value} value
   */
  set(index, value) {
    assertValue(value)
    const newValue = this._value.slice()
    newValue[index] = value
    return this.fresh(newValue, this.actionable)
  }
  /**
   * @param {...Value} items
   */
  append(...items) {
    const newValue = this._value.slice()
    for (const item of items) {
      assertValue(item)
      switch (item.kind) {
        case 'list':
        case 'dict':
        case 'set':
          for (const v of item.asSeq()) newValue.push(v)
          break
        default:
          newValue.push(item)
          break
      }
    }
    return this.fresh(newValue, this.actionable)
  }

  asSeq() {
    return this
  }

  *[Symbol.iterator]() {
    yield* this._value
  }
}

export class BasslineList extends SeqBase {
  /** @returns {'list'}*/
  get kind() {
    return 'list'
  }
}

export class BasslineRecord extends SeqBase {
  get head() {
    return /** @type {Value} */ (this.at(0))
  }

  get fields() {
    return this.value.slice(1)
  }

  /** @returns {'record'} */
  get kind() {
    return 'record'
  }
}

/**
 * @augments {ValueBase<Map<string, Value>>}
 */
export class BasslineSet extends ValueBase {
  /** @param {Value} aValue */
  has(aValue) {
    if (!isValue(aValue))
      throw new TypeError('set member must be a Bassline value')
    return this._value.has(ceKey(aValue))
  }

  /** @param {...Value} items */
  append(...items) {
    const newValue = new Map(this._value)
    for (const item of items) {
      if (!isValue(item))
        throw new TypeError('set member must be a Bassline value')
      switch (item.kind) {
        case 'set':
        case 'list':
        case 'dict':
          for (const v of item.asSeq()) newValue.set(ceKey(v), v)
          break
        default:
          newValue.set(ceKey(item), item)
      }
    }
    return this.fresh(Array.from(newValue.values()), this.actionable)
  }

  get value() {
    return new Map(this._value)
  }

  get length() {
    return this._value.size
  }

  get freshValue() {
    return Array.from(this._value.values())
  }

  copy(actionable = this.actionable) {
    return this.fresh(Array.from(this._value.values()), actionable)
  }

  /**
   * @param {{ (node: Value): Value; (value: Value, index: number, array: Value[]): Value; }} callback
   */
  map(callback) {
    return this.fresh(
      Array.from(this._value.values()).map(callback),
      this.actionable
    )
  }

  /**
   * @param {(value: Value, index: number, array: Value[]) => value is Value} callback
   */
  filter(callback) {
    return this.fresh(
      Array.from(this._value.values()).filter(callback),
      this.actionable
    )
  }

  asSeq() {
    return new BasslineList(Array.from(this._value.values()), this.actionable)
  }

  get values() {
    return this.asSeq()
  }

  /** @returns {'set'} */
  get kind() {
    return 'set'
  }
}

/**
 * @augments {ValueBase<Map<string, [Value, Value]>>}
 */
export class BasslineDict extends ValueBase {
  get value() {
    return new Map(this._value)
  }

  get length() {
    return this._value.size
  }

  asSeq() {
    const entries = []
    for (const [k, v] of this._value.values()) {
      entries.push(new BasslineList([k, v]))
    }
    return new BasslineList(entries, this.actionable)
  }

  /**
   * @param {Value} key
   * @param {Value} value
   */
  set(key, value) {
    return this.fresh([...this.value.values(), [key, value]], this.actionable)
  }

  /** @param {Value} key */
  get(key) {
    if (!isValue(key)) throw new TypeError('dict key must be a Bassline value')
    return this._value.get(ceKey(key))?.[1]
  }

  /** @param {Value} key */
  has(key) {
    return this.get(key) !== undefined
  }

  /** @param {Value} key */
  delete(key) {
    if (!isValue(key)) throw new TypeError('dict key must be a Bassline value')
    const ce = ceKey(key)
    if (this._value.has(ce)) {
      const newValue = this.value
      newValue.delete(ce)
      return this.fresh(Array.from(newValue.values()), this.actionable)
    }
    return this
  }

  /** @param {(value: [Value, Value], index: number, array: [Value, Value][]) => [Value, Value]} callback */
  map(callback) {
    return this.fresh(
      Array.from(this._value.values()).map(callback),
      this.actionable
    )
  }
  /**
   * @param {(value: [Value, Value], index: number, array: [Value, Value][]) => boolean} callback
   */
  filter(callback) {
    return this.fresh(
      Array.from(this._value.values()).filter(callback),
      this.actionable
    )
  }

  get keys() {
    return new BasslineList(Array.from(this._value.values()).map(([k]) => k))
  }

  get values() {
    return new BasslineList(Array.from(this._value.values()).map(([, v]) => v))
  }

  /** @returns {'dict'} */
  get kind() {
    return 'dict'
  }
}

function fallbackHandler(aValue) {
  console.warn('No handler for this value kind: ', aValue)
  return aValue
}

/**
 * @template [T=Value]
 * @param {{[K in ValueKind]?: (value: Values[K]) => T}} handlers
 * @param {(v: Value) => T} fallback
 * @returns {(v: Value) => T}
 */
export function generic(handlers, fallback = fallbackHandler) {
  return v => (handlers?.[v.kind] ?? fallback)(v)
}

export const walk = generic(
  {
    *list(v) {
      yield v
      for (const item of v.value) yield* walk(item)
    },
    *record(v) {
      yield v
      yield* walk(v.head)
      for (const item of v.fields) yield* walk(item)
    },
    *dict(v) {
      yield v
      for (const [key, value] of v.value.values()) {
        yield* walk(key)
        yield* walk(value)
      }
    },
    *set(v) {
      yield v
      for (const member of v.value.values()) yield* walk(member)
    },
  },
  function* (v) {
    yield v
  }
)

/**
 * @param {Value} v
 */
export function hasActionable(v) {
  for (const el of walk(v)) {
    if (el.actionable) return true
  }
  return false
}

/**
 * @param {Value} v
 */
export function cycleFree(v) {
  const seen = new Set()
  for (const el of walk(v)) {
    if (seen.has(el)) return false
    seen.add(el)
  }
  return true
}

/** @param {Value} v */
export const isData = v => (assertValue(v), !hasActionable(v))

/** @param {Value} v */
export const isActionable = v => (assertValue(v), v.actionable)

// ================ Canonical Encoding ================

// All prefix constants
export const BAD_PREFIX = 0x0
export const NIL_PREFIX = 0x1
export const FALSE_PREFIX = 0x2
export const TRUE_PREFIX = 0x3
export const INT_PREFIX = 0x4
export const FLOAT_PREFIX = 0x5
export const STRING_PREFIX = 0x6
export const SYMBOL_PREFIX = 0x7
export const BYTES_PREFIX = 0x8
export const LIST_PREFIX = 0x9
export const DICT_PREFIX = 0xa
export const RECORD_PREFIX = 0xb
export const SET_PREFIX = 0xc

export const ACTIONABLE = 0x80
export const TAG_MASK = 0x7f

export const valueDescriptor = generic({
  nil: v => descriptor(NIL_PREFIX, v.actionable),
  bool: v => descriptor(v.value ? TRUE_PREFIX : FALSE_PREFIX, v.actionable),
  int: v => descriptor(INT_PREFIX, v.actionable),
  float: v => descriptor(FLOAT_PREFIX, v.actionable),
  string: v => descriptor(STRING_PREFIX, v.actionable),
  symbol: v => descriptor(SYMBOL_PREFIX, v.actionable),
  bytes: v => descriptor(BYTES_PREFIX, v.actionable),
  list: v => descriptor(LIST_PREFIX, v.actionable),
  dict: v => descriptor(DICT_PREFIX, v.actionable),
  record: v => descriptor(RECORD_PREFIX, v.actionable),
  set: v => descriptor(SET_PREFIX, v.actionable),
})

// accessor functions for tag & actionable bits
/** @type {(tag: number, actionable: boolean) => number} */
const descriptor = (tag, actionable) => (actionable ? tag | ACTIONABLE : tag)
/** @param {number} b */
const tagOf = b => b & TAG_MASK
/** @param {number} b */
const actionableOf = b => (b & ACTIONABLE) !== 0

const ENC = new TextEncoder()
const DEC = new TextDecoder('utf-8', { fatal: true })
const CANON_NAN = Uint8Array.of(0x7f, 0xf8, 0, 0, 0, 0, 0, 0)

/** @type {WeakMap<Value, Uint8Array>} */
const CE_CACHE = new WeakMap()

/**
 * @param {Value} v
 * @returns {Uint8Array}
 */
export function encode(v) {
  /** @type {number[]} */
  const sink = []
  encodeWithSink(v, sink)
  return Uint8Array.from(sink)
}

/**
 * @param {Value} v
 * @param {number[]} sink
 */
function encodeWithSink(v, sink) {
  const encodeVal = generic({
    nil: prefix,
    bool: prefix,

    float(v) {
      const dv = new DataView(new ArrayBuffer(8))
      dv.setFloat64(0, v.value, false) // big-endian

      prefix(v)
      raw(new Uint8Array(dv.buffer))
    },

    int(v) {
      const b = intToBytes(v.value)

      prefix(v)
      varint(b.length)
      raw(b)
    },

    string(v) {
      const b = ENC.encode(v.value)

      prefix(v)
      varint(b.length)
      raw(b)
    },

    symbol(v) {
      const b = ENC.encode(v.value)

      prefix(v)
      varint(b.length)
      raw(b)
    },

    bytes(v) {
      prefix(v)
      varint(v.value.length)
      raw(v.value)
    },

    list: v => frame(v, enc => v.value.forEach(enc)),
    record: v => frame(v, enc => v.value.forEach(enc)),

    set(v) {
      const members = Array.from(v.value.values())
      members.sort((a, b) => compareBytes(cachedCE(a), cachedCE(b)))
      frame(v, enc => members.forEach(enc))
    },
    dict(v) {
      const entries = Array.from(v.value.values())
      entries.sort((a, b) => compareBytes(cachedCE(a[0]), cachedCE(b[0])))
      frame(v, enc =>
        entries.forEach(([key, value]) => {
          enc(key)
          enc(value)
        })
      )
    },
  })

  encodeVal(v)

  /**
   * @param {Value} value The value to be framed
   * @param {(enc: (v: Value) => void) => void} callback
   */
  function frame(value, callback) {
    const frameSink = []
    callback(e => encodeWithSink(e, frameSink))
    const contents = Uint8Array.from(frameSink)
    prefix(value)
    varint(contents.length)
    raw(contents)
  }

  /** @param {Value} v */
  function prefix(v) {
    return byte(valueDescriptor(v))
  }

  /** @param {number} b */
  function byte(b) {
    sink.push(b & 0xff)
  }

  /** @param {Uint8Array} bytes */
  function raw(bytes) {
    sink.push(...bytes)
  }

  /**@param {number} n */
  function varint(n) {
    let v = n
    while (true) {
      const b = v % 128
      v = Math.floor(v / 128)
      if (v > 0) {
        sink.push(b | 0x80)
      } else {
        sink.push(b)
        return
      }
    }
  }
}

/**
 * Minimal two's-complement big-endian bytes
 * @param {bigint} n The integer to be converted to minimal two's-complement big-endian bytes.
 */
function intToBytes(n) {
  if (n === 0n) return Uint8Array.of(0)
  let width = 1
  while (true) {
    const bits = BigInt(width) * 8n
    const min = -(1n << (bits - 1n))
    const max = (1n << (bits - 1n)) - 1n
    if (n >= min && n <= max) break
    width++
  }
  const out = new Uint8Array(width)
  let v = BigInt.asUintN(width * 8, n)
  for (let i = width - 1; i >= 0; i--) {
    out[i] = Number(v & 0xffn)
    v >>= 8n
  }
  return out
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

/** @param {Uint8Array} bytes */
export function decode(bytes) {
  return BasslineDecoder.one(bytes)
}

/** @param {Uint8Array} bytes */
export function decodeAll(bytes) {
  return BasslineDecoder.all(bytes)
}

/** @param {Value} v */
export function ceKey(v) {
  return Array.from(cachedCE(v))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
}

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
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] - b[i]
  return a.length - b.length
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

export class BasslineDecoder {
  /** @param {Uint8Array} bytes */
  constructor(bytes) {
    this.bytes = bytes
    this.pos = 0
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

  readVarint() {
    let result = 0
    let mul = 1
    let count = 0
    while (true) {
      const b = this.readByte()
      count++
      result += (b & 0x7f) * mul
      if ((b & 0x80) === 0) {
        if (count > 1 && b === 0) throw new Error('non-minimal varint')
        return result
      }
      mul *= 128
    }
  }

  /** @param {Uint8Array} b */
  decodeUtf8(b) {
    return DEC.decode(b)
  }

  /** @param {Uint8Array} b */
  decodeF64(b) {
    const dv = new DataView(b.buffer, b.byteOffset, 8)
    const x = dv.getFloat64(0, false)
    if (Number.isNaN(x) && !bytesEqual(b, CANON_NAN))
      throw new Error('non-canonical NaN')
    return x
  }

  /** @param {Uint8Array} b */
  decodeInt(b) {
    if (b.length >= 2) {
      if (b[0] === 0x00 && (b[1] & 0x80) === 0)
        throw new Error('non-minimal integer')
      if (b[0] === 0xff && (b[1] & 0x80) !== 0)
        throw new Error('non-minimal integer')
    }
    let u = 0n
    for (const byte of b) u = (u << 8n) | BigInt(byte)
    return BigInt.asIntN(b.length * 8, u)
  }

  frameEnd() {
    const len = this.readVarint()
    const end = this.pos + len
    if (end > this.bytes.length) throw new Error('frame length exceeds input')
    return end
  }

  /** @returns {Value} */
  decodeValue() {
    const desc = this.readByte()
    const tag = tagOf(desc)
    const actionable = actionableOf(desc)
    if (tag === BAD_PREFIX) throw new Error('bad prefix 0x0!')
    return this.decodeByTag(tag, actionable)
  }

  /** @param {boolean} actionable */
  decodeList(actionable) {
    const end = this.frameEnd()
    const items = []
    while (this.pos < end) items.push(this.decodeValue())
    if (this.pos !== end) throw new Error('extra bytes at end of list')
    return new BasslineList(items, actionable)
  }

  /** @param {boolean} actionable */
  decodeDict(actionable) {
    const end = this.frameEnd()
    /** @type {[Value, Value][]} */
    const entries = []
    /** @type {Uint8Array | null} */
    let prevKeyCE = null
    while (this.pos < end) {
      const start = this.pos
      const key = this.decodeValue()
      const keyCE = this.bytes.subarray(start, this.pos)
      if (prevKeyCE !== null) {
        const c = compareBytes(prevKeyCE, keyCE)
        if (c > 0) throw new Error('dictionary keys out of order')
        if (c === 0) throw new Error('duplicate dictionary key')
      }
      prevKeyCE = keyCE
      if (this.pos >= end) throw new Error('dict key missing value')
      const value = this.decodeValue()
      entries.push([key, value])
    }
    if (this.pos !== end) throw new Error('extra bytes at end of dictionary')
    return fresh.dict(entries, actionable)
  }

  /** @param {boolean} actionable */
  decodeRecord(actionable) {
    const end = this.frameEnd()
    if (this.pos >= end) throw new Error('record missing head')
    const record = [this.decodeValue()]
    while (this.pos < end) {
      const field = this.decodeValue()
      record.push(field)
    }
    if (this.pos !== end) throw new Error('extra bytes at end of record')
    return fresh.record(record, actionable)
  }

  /** @param {boolean} actionable */
  decodeSet(actionable) {
    const end = this.frameEnd()
    /** @type {Value[]} */
    const members = []
    /** @type {Uint8Array | null} */
    let prevCE = null
    while (this.pos < end) {
      const start = this.pos
      const member = this.decodeValue()
      const ce = this.bytes.subarray(start, this.pos)
      if (prevCE !== null) {
        const c = compareBytes(prevCE, ce)
        if (c > 0) throw new Error('set members out of order')
        if (c === 0) throw new Error('duplicate set member')
      }
      prevCE = ce
      members.push(member)
    }
    if (this.pos !== end) throw new Error('extra bytes at end of set')
    return fresh.set(members, actionable)
  }

  /**
   * @param {number} tag
   * @param {boolean} actionable
   */
  decodeByTag(tag, actionable) {
    switch (tag) {
      case NIL_PREFIX:
        return fresh.nil(actionable)
      case FALSE_PREFIX:
        return fresh.bool(false, actionable)
      case TRUE_PREFIX:
        return fresh.bool(true, actionable)
      case INT_PREFIX: {
        const len = this.readVarint()
        if (len === 0) throw new Error('zero-length integer')
        const int = this.decodeInt(this.readBytes(len))
        return fresh.int(int, actionable)
      }
      case FLOAT_PREFIX: {
        const float = this.decodeF64(this.readBytes(8))
        return fresh.float(float, actionable)
      }
      case STRING_PREFIX: {
        const len = this.readVarint()
        const str = this.decodeUtf8(this.readBytes(len))
        return fresh.string(str, actionable)
      }
      case SYMBOL_PREFIX: {
        const len = this.readVarint()
        return fresh.symbol(this.decodeUtf8(this.readBytes(len)), actionable)
      }
      case BYTES_PREFIX: {
        const len = this.readVarint()
        return fresh.bytes(this.readBytes(len), actionable)
      }
      case LIST_PREFIX:
        return this.decodeList(actionable)
      case DICT_PREFIX:
        return this.decodeDict(actionable)
      case RECORD_PREFIX:
        return this.decodeRecord(actionable)
      case SET_PREFIX:
        return this.decodeSet(actionable)
      default:
        throw new Error('unknown tag 0x' + tag.toString(16))
    }
  }

  /**
   * @param {Uint8Array} input
   * @returns {Value}
   */
  static one(input) {
    const dec = new BasslineDecoder(input)
    const val = dec.decodeValue()
    if (dec.pos !== input.length) throw new Error('extra bytes at end of input')
    return val
  }

  /**
   * @param {Uint8Array} input
   * @returns {Value[]}
   */
  static all(input) {
    const dec = new BasslineDecoder(input)
    const values = []
    while (dec.pos < input.length) {
      values.push(dec.decodeValue())
    }
    return values
  }
}

/**
 * @param {unknown} x
 * @returns {x is Scalar}
 */
export function isScalar(x) {
  return [
    BasslineNil,
    BasslineBool,
    BasslineInt,
    BasslineFloat,
    BasslineString,
    BasslineSymbol,
    BasslineBytes,
  ].some(aClass => x instanceof aClass)
}

/**
 * @param {unknown} x
 * @returns {x is Frame}
 */
export function isFrame(x) {
  return [BasslineList, BasslineDict, BasslineRecord, BasslineSet].some(
    aClass => x instanceof aClass
  )
}

/** @param {unknown} x */
export function isValue(x) {
  return isScalar(x) || isFrame(x)
}

/**
 * @param {unknown} x
 * @param {string} [msg] - The error message to throw if x is not a Bassline value
 * @throws {TypeError} if x is not a Bassline value.
 * @returns {x is Value}
 */
export function assertValue(x, msg = 'expected a Bassline value') {
  if (!isValue(x)) throw new TypeError(msg)
  return true
}

/**
 * @template V
 * @template {ValueKind} K
 * @typedef {{
 * readonly value: V
 * readonly kind: K
 * actionable(): boolean
 * actionable(a: boolean): AltValue<V, K>
 * }} AltValue
 */

/**
 * @typedef {{
 * nil: BasslineNil
 * bool: BasslineBool
 * int: BasslineInt
 * float: BasslineFloat
 * string: BasslineString
 * symbol: BasslineSymbol
 * bytes: BasslineBytes
 * }} ScalarValues
 */

/**
 * @typedef {{
 * list: BasslineList
 * dict: BasslineDict
 * record: BasslineRecord
 * set: BasslineSet
 * }} FrameValues
 */

/**
 * @template T
 * @typedef {{
 * readonly actionable: boolean
 * readonly value: T
 * readonly kind: ValueKind
 * copy(actionable: boolean): BasslineVal<T>
 * eq(other: Value): boolean
 * encode(): Uint8Array<ArrayBuffer>
 * ceKey(): string,
 * }} BasslineVal
 */

/** @typedef {ScalarValues & FrameValues} Values */
/** @typedef {ScalarValues[keyof ScalarValues]} Scalar */
/** @typedef {FrameValues[keyof FrameValues]} Frame */
/** @typedef {Values[keyof Values]} Value */
/** @typedef { keyof Values } ValueKind */
