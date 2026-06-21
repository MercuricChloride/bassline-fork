// @ts-check
// Reference implementation of the Bassline Data Model
// Each value type is implemented as a subclass of BasslineValue
// Each value has a single canonical encoding which determines it's identity
// There are 7 atomic value types:
// NIL, true, false, int, float, string, symbol
// Alongside 4 frame value types:
// list, dict, record, set

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
 * accept(aVisitor: BasslineVisitor): BasslineVal<T>
 * }} BasslineVal
 */

/** @typedef {ScalarValues & FrameValues} Values */
/** @typedef {ScalarValues[keyof ScalarValues]} Scalar */
/** @typedef {FrameValues[keyof FrameValues]} Frame */
/** @typedef {Values[keyof Values]} Value */
/** @typedef { keyof Values } ValueKind */

/** @type {(x: unknown) => x is Scalar} */
export const isScalar = x =>
  [
    BasslineNil,
    BasslineBool,
    BasslineInt,
    BasslineFloat,
    BasslineString,
    BasslineSymbol,
    BasslineBytes,
  ].some(aClass => x instanceof aClass)
/** @type {(x: unknown) => x is Frame} */
export const isFrame = x =>
  [BasslineList, BasslineDict, BasslineRecord, BasslineSet].some(
    aClass => x instanceof aClass
  )

/** @type {(x: unknown) => x is Value} */
export const isValue = x => isScalar(x) || isFrame(x)

/**
 * @param {unknown} x
 * @param msg
 * @throws {TypeError} if x is not a Bassline value.
 * @returns {x is Value}
 */
export function assertValue(x, msg = 'expected a Bassline value') {
  if (!isValue(x)) throw new TypeError(msg)
  return true
}

// ================ Bassline Value Types ================

/** @template T */
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

  encode() {
    // Note: This is fine because this class is logically abstract
    //@ts-expect-error
    return encode(this)
  }

  ceKey() {
    // Note: This is fine because this class is logically abstract
    //@ts-expect-error
    return ceKey(this)
  }

  /**
   * @param {T} value
   * @param {boolean} actionable
   */
  fresh(value, actionable = this.actionable) {
    const Ctor = /** @type {new (value: T, actionable: boolean) => this} */ (
      this.constructor
    )
    return new Ctor(value, actionable)
  }

  copy(actionable = this.actionable) {
    return this.fresh(this.value, actionable)
  }

  /** @param {Value} other */
  eq(other) {
    // Note: This is fine because this class is logically abstract
    //@ts-expect-error
    return eq(this, other)
  }
}

/** @augments {ValueBase<null>} */
export class BasslineNil extends ValueBase {
  constructor(actionable = false) {
    super(null, actionable)
  }
  /**
   * @param {null} _value
   * @param {boolean} actionable
   */
  fresh(_value, actionable = this.actionable) {
    const Ctor = /** @type {new (actionable: boolean) => this} */ (
      this.constructor
    )
    return new Ctor(actionable)
  }
  /** @param {BasslineVisitor} aVisitor */
  accept(aVisitor) {
    return aVisitor.visitNil(this)
  }
  /** @returns {'nil'} */
  get kind() {
    return 'nil'
  }
}

/** @augments {ValueBase<boolean>} */
export class BasslineBool extends ValueBase {
  /**
   * @param {boolean} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    if (typeof value !== 'boolean')
      throw new TypeError('bool expects a Boolean')
    super(value, actionable)
  }
  /** @param {BasslineVisitor} aVisitor */
  accept(aVisitor) {
    return aVisitor.visitBool(this)
  }
  /** @returns {'bool'}*/
  get kind() {
    return 'bool'
  }
}

/** @augments {ValueBase<bigint>} */
export class BasslineInt extends ValueBase {
  /**
   * @param {bigint | number} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    if (typeof value === 'number') {
      super(BigInt(value), actionable)
    } else if (typeof value === 'bigint') {
      super(value, actionable)
    } else {
      throw new TypeError('int expects a BigInt or Number')
    }
  }

  /** @param {BasslineVisitor} aVisitor */
  accept(aVisitor) {
    return aVisitor.visitInt(this)
  }
  /** @returns {'int'}*/
  get kind() {
    return 'int'
  }
}

/** @augments {ValueBase<number>} */
export class BasslineFloat extends ValueBase {
  /**
   * @param {number} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    if (typeof value !== 'number') throw new TypeError('float expects a Number')
    if (Number.isNaN(value)) {
      super(NaN, actionable)
    } else {
      super(value, actionable)
    }
  }
  /** @param {BasslineVisitor} aVisitor */
  accept(aVisitor) {
    return aVisitor.visitFloat(this)
  }
  /** @returns {'float'}*/
  get kind() {
    return 'float'
  }
}

/** @augments {ValueBase<string>} */
export class BasslineString extends ValueBase {
  /**
   * @param {string} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    if (typeof value !== 'string') throw new TypeError('str expects a string')
    if (!value.isWellFormed()) throw new Error('string is not well-formed')
    super(value, actionable)
  }

  /** @param {BasslineVisitor} aVisitor */
  accept(aVisitor) {
    return aVisitor.visitString(this)
  }

  /** @returns {'string'}*/
  get kind() {
    return 'string'
  }
}

/** @augments {ValueBase<string>} */
export class BasslineSymbol extends ValueBase {
  /**
   * @param {string} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    if (typeof value !== 'string') {
      console.error('symbol expects a string, but got:', value)
      throw new TypeError('symbol expects a string')
    }
    if (!value.isWellFormed())
      throw new Error('symbol string is not well-formed')
    super(value, actionable)
  }

  /** @param {BasslineVisitor} aVisitor */
  accept(aVisitor) {
    return aVisitor.visitSymbol(this)
  }
  /** @returns {'symbol'}*/
  get kind() {
    return 'symbol'
  }
}

/** @augments {ValueBase<Uint8Array>} */
export class BasslineBytes extends ValueBase {
  /**
   * @param {Uint8Array} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    if (!(value instanceof Uint8Array))
      throw new TypeError('bytes expects a Uint8Array')
    super(value.slice(), actionable)
  }
  get value() {
    return this._value.slice()
  }
  /** @param {BasslineVisitor} aVisitor */
  accept(aVisitor) {
    return aVisitor.visitBytes(this)
  }
  /** @returns {'bytes'}*/
  get kind() {
    return 'bytes'
  }
}

/**
 * @augments {ValueBase<Value[]>}
 */
class SeqBase extends ValueBase {
  /**
   * @param {Value[]} items
   * @param {boolean} actionable
   */
  constructor(items, actionable = false) {
    if (!Array.isArray(items) || !items.every(isValue)) {
      throw new TypeError('seq expects an array of Bassline values')
    }
    super(items.slice(), actionable)
  }
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
   * @returns {this}
   */
  map(callback) {
    const mapped = this._value.map(callback)
    return this.fresh(mapped, this.actionable)
  }
  /**
   * @param {(item: Value, index: number, array: Value[]) => boolean} callback
   * @returns {this}
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
   * @returns {this}
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
    newValue.push(...items)
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
  /** @param {BasslineVisitor} visitor */
  accept(visitor) {
    return visitor.visitList(this)
  }
  /** @returns {'list'}*/
  get kind() {
    return 'list'
  }
}

export class BasslineRecord extends SeqBase {
  /**
   * @param {Value[]} record
   * @param {boolean} actionable
   */
  constructor(record, actionable = false) {
    if (record.length === 0) {
      throw new TypeError('record must be a non-empty array of Bassline values')
    }
    super(record, actionable)
  }

  /** @param {BasslineVisitor} visitor */
  accept(visitor) {
    return visitor.visitRecord(this)
  }

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
  /**
   * @param {Value[]} members
   * @param {boolean} actionable
   */
  constructor(members, actionable = false) {
    /** @type {Map<string, Value>} */
    const value = new Map()
    for (const m of members) {
      if (!isValue(m))
        throw new TypeError('set member must be a Bassline value')
      const key = m.ceKey()
      value.set(key, m)
    }
    super(value, actionable)
  }

  /** @param {BasslineVisitor} visitor */
  accept(visitor) {
    return visitor.visitSet(this)
  }

  /** @param {Value} aValue */
  has(aValue) {
    if (!isValue(aValue))
      throw new TypeError('set member must be a Bassline value')
    return this._value.has(aValue.ceKey())
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
          for (const v of item.asSeq()) newValue.set(v.ceKey(), v)
          break
        default:
          newValue.set(item.ceKey(), item)
      }
    }
    return new BasslineSet(Array.from(newValue.values()), this.actionable)
  }

  get value() {
    return new Map(this._value)
  }

  asSeq() {
    return new BasslineList(Array.from(this._value.values()), this.actionable)
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
  /**
   * @param {Array<[Value, Value]>} entries
   * @param {boolean} actionable
   */
  constructor(entries, actionable = false) {
    /** @type {Map<string, [Value, Value]>} */
    const values = new Map()
    for (const [k, v] of entries) {
      if (!isValue(k) || !isValue(v))
        throw new TypeError('dict entry must be [Value, Value]')
      const keyCe = k.ceKey()
      values.set(keyCe, [k, v])
    }
    super(values, actionable)
  }

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
    return new BasslineDict(
      [...this.value.values(), [key, value]],
      this.actionable
    )
  }

  /** @param {Value} key */
  get(key) {
    if (!isValue(key)) throw new TypeError('dict key must be a Bassline value')
    return this._value.get(key.ceKey())?.[1]
  }

  /** @param {Value} key */
  has(key) {
    return this.get(key) !== undefined
  }

  /** @param {Value} key */
  delete(key) {
    if (!isValue(key)) throw new TypeError('dict key must be a Bassline value')
    const ce = key.ceKey()
    if (this._value.has(ce)) {
      const newValue = this.value
      newValue.delete(ce)
      return new BasslineDict(Array.from(newValue.values()), this.actionable)
    }
    return this
  }

  /**
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitDict(this)
  }

  /** @returns {'dict'} */
  get kind() {
    return 'dict'
  }
}

// ================ factories ================
/** @type {<T extends new (...args: any[]) => any>(aClass: T) => (...args: ConstructorParameters<T>) => InstanceType<T>} */
const factory =
  aClass =>
  (...args) =>
    new aClass(...args)
export const nil = factory(BasslineNil)
export const bool = factory(BasslineBool)
export const int = factory(BasslineInt)
export const float = factory(BasslineFloat)
export const str = factory(BasslineString)
export const sym = factory(BasslineSymbol)
export const bytes = factory(BasslineBytes)
export const list = factory(BasslineList)
export const dict = factory(BasslineDict)
export const record = factory(BasslineRecord)
export const set = factory(BasslineSet)

export class BasslineVisitor {
  /** @param {Value} aValue */
  process(aValue) {
    this.visit(aValue)
    return this
  }
  /** @param {Value} aValue */
  visit(aValue) {
    return aValue.accept(this)
  }
  /** @param {BasslineNil} aNil */
  visitNil(aNil) {
    return aNil
  }
  /** @param {BasslineBool} aBool */
  visitBool(aBool) {
    return aBool
  }
  /** @param {BasslineInt} anInt */
  visitInt(anInt) {
    return anInt
  }
  /** @param {BasslineFloat} aFloat */
  visitFloat(aFloat) {
    return aFloat
  }
  /** @param {BasslineString} aString */
  visitString(aString) {
    return aString
  }
  /** @param {BasslineSymbol} aSymbol */
  visitSymbol(aSymbol) {
    return aSymbol
  }
  /** @param {BasslineBytes} aBytes */
  visitBytes(aBytes) {
    return aBytes
  }
  /** @param {BasslineList} aList */
  visitList(aList) {
    for (const item of aList.value) {
      this.visit(item)
    }
    return aList
  }
  /** @param {BasslineDict} aDict */
  visitDict(aDict) {
    for (const [key, value] of aDict.value.values()) {
      this.visit(key)
      this.visit(value)
    }
    return aDict
  }
  /** @param {BasslineRecord} aRecord */
  visitRecord(aRecord) {
    for (const item of aRecord) this.visit(item)
    return aRecord
  }
  /** @param {BasslineSet} aSet */
  visitSet(aSet) {
    for (const member of aSet.value.values()) this.visit(member)
    return aSet
  }
}

class ActionableVisitor extends BasslineVisitor {
  foundActionable = false
  /** @param {Value} aValue */
  visit(aValue) {
    if (aValue.actionable) {
      this.foundActionable = true
      return aValue
    }
    return super.visit(aValue)
  }
}

class CycleVisitor extends BasslineVisitor {
  seen = new Set()
  cycle = false
  /** @param {Value} aValue */
  visit(aValue) {
    if (this.cycle) return aValue
    if (this.seen.has(aValue)) {
      this.cycle = true
      return aValue
    }
    this.seen.add(aValue)
    return super.visit(aValue)
  }
}

/** @param {Value} v */
export const hasActionable = v =>
  new ActionableVisitor().process(v).foundActionable

/** @param {Value} v */
export const cycleFree = v => !new CycleVisitor().process(v).cycle

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
export class CEVisitor extends BasslineVisitor {
  /** @type {number[]} */
  sink = []
  /** @param {number} b */
  byte(b) {
    this.sink.push(b & 0xff)
    return this
  }
  /** @param {Uint8Array} u8 */
  raw(u8) {
    for (let i = 0; i < u8.length; i++) this.sink.push(u8[i])
    return this
  }
  /** @param {number} n */
  varint(n) {
    let v = n
    while (true) {
      const b = v % 128
      v = Math.floor(v / 128)
      if (v > 0) {
        this.sink.push(b | 0x80)
      } else {
        this.sink.push(b)
        return this
      }
    }
  }
  toUint8Array() {
    return Uint8Array.from(this.sink)
  }

  /**
   * Encodes a frame consisting of a descriptor byte, a varint length, and the body bytes.
   * The body is built in a subvisitor so it's length is known before writing.
   * @param {number} tag prefix tag to encode
   * @param {boolean} actionable whether or not the value is actionable
   * @param {(body: CEVisitor) => void} emit function that receives a sub-visitor to build the frame body
   */
  frame(tag, actionable, emit) {
    const body = new CEVisitor()
    emit(body)
    this.byte(descriptor(tag, actionable)).varint(body.sink.length)
    for (const b of body.sink) this.sink.push(b)
    return this
  }
  /** @param {BasslineNil} aNil */
  visitNil(aNil) {
    this.byte(descriptor(NIL_PREFIX, aNil.actionable))
    return aNil
  }

  /** @param {BasslineBool} aBool */
  visitBool(aBool) {
    const tag = aBool.value ? TRUE_PREFIX : FALSE_PREFIX
    this.byte(descriptor(tag, aBool.actionable))
    return aBool
  }
  /** @param {BasslineInt} anInt */
  visitInt(anInt) {
    const b = intToBytes(anInt.value)
    this.byte(descriptor(INT_PREFIX, anInt.actionable)).varint(b.length).raw(b)
    return anInt
  }
  /** @param {BasslineFloat} aFloat */
  visitFloat(aFloat) {
    const dv = new DataView(new ArrayBuffer(8))
    dv.setFloat64(0, aFloat.value, false) // big-endian
    this.byte(descriptor(FLOAT_PREFIX, aFloat.actionable)).raw(
      new Uint8Array(dv.buffer)
    )
    return aFloat
  }
  /** @param {BasslineString} aString */
  visitString(aString) {
    const u8 = ENC.encode(aString.value)
    this.byte(descriptor(STRING_PREFIX, aString.actionable))
      .varint(u8.length)
      .raw(u8)
    return aString
  }
  /** @param {BasslineSymbol} aSymbol */
  visitSymbol(aSymbol) {
    const u8 = ENC.encode(aSymbol.value)
    this.byte(descriptor(SYMBOL_PREFIX, aSymbol.actionable))
      .varint(u8.length)
      .raw(u8)
    return aSymbol
  }
  /** @param {BasslineBytes} aBytes */
  visitBytes(aBytes) {
    this.byte(descriptor(BYTES_PREFIX, aBytes.actionable))
      .varint(aBytes.value.length)
      .raw(aBytes.value)
    return aBytes
  }
  /** @param {BasslineList} aList */
  visitList(aList) {
    this.frame(LIST_PREFIX, aList.actionable, body => {
      for (const c of aList.value) body.visit(c)
    })
    return aList
  }
  /** @param {BasslineDict} aDict */
  visitDict(aDict) {
    const entries = Array.from(aDict.value.values())
    entries.sort((a, b) => compareBytes(cachedCE(a[0]), cachedCE(b[0])))
    this.frame(DICT_PREFIX, aDict.actionable, body => {
      for (const [k, v] of entries) {
        body.visit(k)
        body.visit(v)
      }
    })
    return aDict
  }
  /** @param {BasslineRecord} aRecord */
  visitRecord(aRecord) {
    this.frame(RECORD_PREFIX, aRecord.actionable, body => {
      for (const item of aRecord.value) body.visit(item)
    })
    return aRecord
  }
  /** @param {BasslineSet} aSet */
  visitSet(aSet) {
    const members = Array.from(aSet.value.values())
    members.sort((a, b) => compareBytes(cachedCE(a), cachedCE(b)))
    this.frame(SET_PREFIX, aSet.actionable, body => {
      for (const m of members) body.visit(m)
    })
    return aSet
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
    const visitor = new CEVisitor()
    visitor.visit(v)
    b = visitor.toUint8Array()
    CE_CACHE.set(v, b)
  }
  return b
}

/** @param {Value} v*/
export function encode(v) {
  assertValue(v)
  return cachedCE(v).slice()
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
    return new BasslineDict(entries, actionable)
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
    return new BasslineRecord(record, actionable)
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
    return new BasslineSet(members, actionable)
  }

  /**
   * @param {number} tag
   * @param {boolean} actionable
   */
  decodeByTag(tag, actionable) {
    switch (tag) {
      case NIL_PREFIX:
        return new BasslineNil(actionable)
      case FALSE_PREFIX:
        return new BasslineBool(false, actionable)
      case TRUE_PREFIX:
        return new BasslineBool(true, actionable)
      case INT_PREFIX: {
        const len = this.readVarint()
        if (len === 0) throw new Error('zero-length integer')
        const int = this.decodeInt(this.readBytes(len))
        return new BasslineInt(int, actionable)
      }
      case FLOAT_PREFIX: {
        const float = this.decodeF64(this.readBytes(8))
        return new BasslineFloat(float, actionable)
      }
      case STRING_PREFIX: {
        const len = this.readVarint()
        const str = this.decodeUtf8(this.readBytes(len))
        return new BasslineString(str, actionable)
      }
      case SYMBOL_PREFIX: {
        const len = this.readVarint()
        return new BasslineSymbol(
          this.decodeUtf8(this.readBytes(len)),
          actionable
        )
      }
      case BYTES_PREFIX: {
        const len = this.readVarint()
        return new BasslineBytes(this.readBytes(len), actionable)
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
