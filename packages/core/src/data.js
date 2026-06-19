// @ts-check
// Reference implementation of the Bassline Data Model
// Each value type is implemented as a subclass of BasslineValue
// Each value has a single canonical encoding which determines it's identity
// There are 7 atomic value types:
// NIL, true, false, int, float, string, symbol
// Alongside 4 frame value types:
// list, dict, record, set

/**
 * @typedef {"nil" | "bool" | "int" | "float" | "string" | "symbol" | "list" | "dict" | "record" | "set"} ValueKind
 */

/**
 * @typedef {BasslineNil | BasslineBool | BasslineInt | BasslineFloat | BasslineString | BasslineSymbol | BasslineBytes } Scalar
 */

/**
 * @typedef {BasslineList | BasslineDict | BasslineSet | BasslineRecord } Frame
 */

/**
 * @typedef {Frame | Scalar} Value
 */

/** @type {(x: unknown) => x is BasslineValue} */
export const isValue = x => x instanceof BasslineValue

/**
 * @param {unknown} x
 * @throws {TypeError} if x is not a Bassline value.
 * @returns {x is BasslineValue}
 */
export function assertValue(x) {
  if (!isValue(x)) throw new TypeError('expected a Bassline value')
  return true
}

// ================ Bassline Value Types ================

export class BasslineValue {
  #actionable
  constructor(actionable = false) {
    if (new.target === BasslineValue)
      throw new Error('BasslineValue is abstract')
    this.#actionable = actionable
  }

  get actionable() {
    return this.#actionable
  }

  get isFrame() {
    return false
  }

  toStatic() {
    if (this.#actionable) {
      return this.copy(false)
    } else {
      return this
    }
  }

  toActionable() {
    if (!this.#actionable) {
      return this.copy(true)
    } else {
      return this
    }
  }

  /**
   * @param {BasslineVisitor} _aVisitor
   */
  accept(_aVisitor) {
    throw new Error('abstract')
  }

  /**
   * @param {boolean} _actionable
   */
  copy(_actionable) {
    throw new Error('abstract')
  }

  encode() {
    return encode(this)
  }

  ceKey() {
    return ceKey(this)
  }

  /**
   *
   * @param {Value} other
   */
  eq(other) {
    return eq(this, other)
  }

  /**
   *
   * @param {BasslineValue} other
   */
  compareBytes(other) {
    return compareBytes(this.encode(), other.encode())
  }
}

export class BasslineNil extends BasslineValue {
  get value() {
    return null
  }
  copy(actionable = this.actionable) {
    return new BasslineNil(actionable)
  }
  /**
   *
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitNil(this)
  }
  get kind() {
    return 'nil'
  }
}

export class BasslineBool extends BasslineValue {
  #value
  /**
   *
   * @param {boolean} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    if (typeof value !== 'boolean')
      throw new TypeError('bool expects a Boolean')
    super(actionable)
    this.#value = value
  }
  get value() {
    return this.#value
  }
  copy(actionable = this.actionable) {
    return new BasslineBool(this.value, actionable)
  }
  /**
   *
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitBool(this)
  }
  get kind() {
    return 'bool'
  }
}

export class BasslineInt extends BasslineValue {
  #value
  /**
   *
   * @param {bigint | number} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    super(actionable)
    if (typeof value === 'number') {
      this.#value = BigInt(value)
    } else if (typeof value === 'bigint') {
      this.#value = value
    } else {
      throw new TypeError('int expects a BigInt or Number')
    }
  }

  get value() {
    return this.#value
  }

  /**
   *
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitInt(this)
  }
  get kind() {
    return 'int'
  }
  copy(actionable = this.actionable) {
    return new BasslineInt(this.value, actionable)
  }
}

export class BasslineFloat extends BasslineValue {
  #value
  /**
   *
   * @param {number} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    super(actionable)
    if (typeof value !== 'number') throw new TypeError('float expects a Number')
    if (Number.isNaN(value)) {
      this.#value = NaN
    } else {
      this.#value = value
    }
  }

  get value() {
    return this.#value
  }

  /**
   *
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitFloat(this)
  }
  copy(actionable = this.actionable) {
    return new BasslineFloat(this.value, actionable)
  }
  get kind() {
    return 'float'
  }
}

export class BasslineString extends BasslineValue {
  #value
  /**
   *
   * @param {string} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    if (typeof value !== 'string') throw new TypeError('str expects a string')
    if (!value.isWellFormed()) throw new Error('string is not well-formed')
    super(actionable)
    this.#value = value
  }

  get value() {
    return this.#value
  }

  /**
   *
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitString(this)
  }

  copy(actionable = this.actionable) {
    return new BasslineString(this.value, actionable)
  }
  get kind() {
    return 'string'
  }
}

export class BasslineSymbol extends BasslineValue {
  #value
  /**
   *
   * @param {string} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    super(actionable)
    if (typeof value !== 'string') {
      console.error('symbol expects a string, but got:', value)
      throw new TypeError('symbol expects a string')
    }
    if (!value.isWellFormed())
      throw new Error('symbol string is not well-formed')
    this.#value = value
  }

  get value() {
    return this.#value
  }

  /**
   *
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitSymbol(this)
  }
  copy(actionable = this.actionable) {
    return new BasslineSymbol(this.value, actionable)
  }
  get kind() {
    return 'symbol'
  }
}

export class BasslineBytes extends BasslineValue {
  #value
  /**
   *
   * @param {Uint8Array} value
   * @param {boolean} actionable
   */
  constructor(value, actionable = false) {
    if (!(value instanceof Uint8Array))
      throw new TypeError('bytes expects a Uint8Array')
    super(actionable)
    this.#value = value.slice()
  }

  get value() {
    return this.#value.slice()
  }
  /**
   *
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitBytes(this)
  }
  get kind() {
    return 'bytes'
  }

  copy(actionable = this.actionable) {
    return new BasslineBytes(this.value, actionable)
  }
}

export class BasslineList extends BasslineValue {
  #value
  /**
   *
   * @param {BasslineValue[]} items
   * @param {boolean} actionable
   */
  constructor(items, actionable = false) {
    if (!Array.isArray(items) || !items.every(isValue)) {
      throw new TypeError('list expects an array of Bassline values')
    }
    super(actionable)
    this.#value = items.slice()
  }

  get isFrame() {
    return true
  }

  /**
   *
   * @param {number} index
   */
  at(index) {
    if (typeof index !== 'number') throw new TypeError('index must be a number')
    return this.#value.at(index)
  }

  length() {
    return this.#value.length
  }

  /**
   *
   * @param  {...BasslineValue} items
   * @returns {BasslineList}
   */
  append(...items) {
    return new BasslineList([...this.#value, ...items], this.actionable)
  }

  /**
   *
   * @param {(item: BasslineValue, index: number, array: BasslineValue[]) => BasslineValue} callback
   * @returns {BasslineList}
   */
  map(callback) {
    return new BasslineList(this.#value.map(callback), this.actionable)
  }

  /**
   *
   * @param {(item: BasslineValue, index: number, array: BasslineValue[]) => boolean} callback
   * @returns {BasslineList}
   */
  filter(callback) {
    return new BasslineList(this.#value.filter(callback), this.actionable)
  }

  get value() {
    return this.#value.slice()
  }

  *[Symbol.iterator]() {
    yield* this.value
  }

  /**
   *
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitList(this)
  }

  copy(actionable = this.actionable) {
    return new BasslineList(this.value, actionable)
  }

  get kind() {
    return 'list'
  }
}

export class BasslineDict extends BasslineValue {
  #value
  #cache
  /**
   *
   * @param {Array<[BasslineValue, BasslineValue]>} entries
   * @param {boolean} actionable
   */
  constructor(entries, actionable = false) {
    const value = new Map()
    const cache = new Map()
    for (const [k, v] of entries) {
      if (!isValue(k) || !isValue(v))
        throw new TypeError('dict entry must be [Value, Value]')
      const key = k.ceKey()
      value.set(key, v)
      cache.set(key, k)
    }
    super(actionable)
    this.#value = value
    this.#cache = cache
  }

  get isFrame() {
    return true
  }

  /**
   * @returns {Map<BasslineValue, BasslineValue>}
   */
  get value() {
    const result = new Map()
    for (const [key, val] of this.#value) {
      const origKey = this.#cache.get(key)
      if (!origKey) throw new Error('rebuild: missing original key in cache')
      result.set(origKey, val)
    }
    return result
  }

  /**
   *
   * @param {(entry: [BasslineValue, BasslineValue], index: number, array: [BasslineValue, BasslineValue][]) => [BasslineValue, BasslineValue]} callback
   */
  map(callback) {
    return new BasslineDict(
      Array.from(this.value).map(callback),
      this.actionable
    )
  }

  /**
   *
   * @param {(entry: [BasslineValue, BasslineValue], index: number, array: [BasslineValue, BasslineValue][]) => boolean} callback
   */
  filter(callback) {
    return new BasslineDict(
      Array.from(this.value).filter(callback),
      this.actionable
    )
  }

  /**
   *
   * @param {...[BasslineValue, BasslineValue]} entries
   */
  append(...entries) {
    return new BasslineDict([...this.value, ...entries], this.actionable)
  }

  /**
   *
   * @param {...BasslineValue} keys
   */
  delete(...keys) {
    const byKey = new Map(this.#value)
    for (const k of keys) {
      if (!isValue(k)) throw new TypeError('dict key must be a Bassline value')
      byKey.delete(k.ceKey())
    }
    return new BasslineDict(
      Array.from(byKey, ([k, v]) => [this.#cache.get(k), v]),
      this.actionable
    )
  }

  /**
   *
   * @param {BasslineValue} k
   * @param {BasslineValue} v
   * @returns {BasslineDict}
   */
  set(k, v) {
    return this.append([k, v])
  }

  /**
   *
   * @param {BasslineValue} k
   * @returns {BasslineValue}
   */
  get(k) {
    if (!isValue(k)) throw new TypeError('dict key must be a Bassline value')
    return this.#value.get(k.ceKey())
  }

  /**
   *
   * @param {BasslineValue} k
   * @returns {boolean}
   */
  has(k) {
    if (!isValue(k)) throw new TypeError('dict key must be a Bassline value')
    return this.#value.has(k.ceKey())
  }

  *[Symbol.iterator]() {
    for (const [k, v] of this.#value) {
      const origKey = this.#cache.get(k)
      if (!origKey) throw new Error('rebuild: missing original key in cache')
      yield [origKey, v]
    }
  }

  /**
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitDict(this)
  }

  /**
   *
   * @param {boolean} actionable
   * @returns {BasslineDict}
   */
  copy(actionable) {
    return new BasslineDict([...this.value], actionable)
  }

  get kind() {
    return 'dict'
  }
}

export class BasslineRecord extends BasslineValue {
  #value
  /**
   *
   * @param {BasslineValue[]} record
   * @param {boolean} actionable
   */
  constructor(record, actionable = false) {
    const [head, ...fields] = record
    if (!isValue(head))
      throw new TypeError('record head must be a Bassline value')
    if (!Array.isArray(fields) || !fields.every(isValue)) {
      throw new TypeError('record fields must be an array of Bassline values')
    }
    super(actionable)
    this.#value = [head, ...fields]
  }

  get isFrame() {
    return true
  }

  get value() {
    return this.#value.slice()
  }

  get head() {
    return this.value[0]
  }

  get fields() {
    return this.value.slice(1)
  }

  /**
   *
   * @param {(value: BasslineValue, index: number, array: BasslineValue[]) => BasslineValue} callback
   */
  map(callback) {
    return new BasslineRecord(this.value.map(callback), this.actionable)
  }

  /**
   *
   * @param {(value: BasslineValue, index: number, array: BasslineValue[]) => boolean} callback
   * @returns {BasslineRecord}
   */
  filter(callback) {
    return new BasslineRecord(this.value.filter(callback), this.actionable)
  }

  /**
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitRecord(this)
  }

  /**
   *
   * @param {boolean} actionable
   * @returns {BasslineRecord}
   */
  copy(actionable) {
    return new BasslineRecord(this.value, actionable)
  }

  get kind() {
    return 'record'
  }
}

export class BasslineSet extends BasslineValue {
  #value
  /**
   *
   * @param {BasslineValue[]} members
   * @param {boolean} actionable
   */
  constructor(members, actionable = false) {
    const value = new Map()
    for (const m of members) {
      if (!isValue(m))
        throw new TypeError('set member must be a Bassline value')
      const key = m.ceKey()
      value.set(key, m)
    }
    super(actionable)
    this.#value = value
  }

  get isFrame() {
    return true
  }

  /**
   * @returns {BasslineValue[]}
   */
  get value() {
    return Array.from(this.#value.values())
  }

  /**
   *
   * @param {(value: BasslineValue, index: number, array: BasslineValue[]) => BasslineValue} callback
   * @returns {BasslineSet}
   */
  map(callback) {
    return new BasslineSet(this.value.map(callback), this.actionable)
  }

  /**
   *
   * @param {(value: BasslineValue, index: number, array: BasslineValue[]) => boolean} callback
   * @returns {BasslineSet}
   */
  filter(callback) {
    return new BasslineSet(this.value.filter(callback), this.actionable)
  }

  /**
   *
   * @param {...BasslineValue} members
   * @returns {BasslineSet}
   */
  append(...members) {
    const s = new Map(this.#value)
    for (const m of members) {
      if (!isValue(m))
        throw new TypeError('set member must be a Bassline value')
      const key = m.ceKey()
      if (s.has(key)) continue
      else s.set(key, m)
    }
    return new BasslineSet(Array.from(s.values()), this.actionable)
  }

  /**
   *
   * @param {...BasslineValue} members
   * @returns {BasslineSet}
   */
  delete(...members) {
    const s = new Map(this.#value)
    for (const m of members) {
      if (!isValue(m))
        throw new TypeError('set member must be a Bassline value')
      s.delete(m.ceKey())
    }
    return new BasslineSet(Array.from(s.values()), this.actionable)
  }

  /**
   *
   * @param {BasslineValue} m
   * @returns {BasslineSet}
   */
  add(m) {
    return this.append(m)
  }

  /**
   *
   * @param {...BasslineValue} members
   * @returns {boolean}
   */
  has(...members) {
    for (const m of members) {
      if (!isValue(m))
        throw new TypeError('set member must be a Bassline value')
      if (!this.#value.has(m.ceKey())) return false
    }
    return true
  }

  *[Symbol.iterator]() {
    yield* this.#value.values()
  }

  /**
   * @template {BasslineVisitor} T
   * @param {T} aVisitor
   */
  accept(aVisitor) {
    return aVisitor.visitSet(this)
  }

  copy(actionable = this.actionable) {
    return new BasslineSet(this.value, actionable)
  }

  get kind() {
    return 'set'
  }
}

// ================ factories ================
export const nil = () => new BasslineNil()
/** @type {(b: boolean) => BasslineBool} */
export const bool = b => new BasslineBool(b)
/** @type {(n: number | bigint) => BasslineInt} */
export const int = n => new BasslineInt(n)
/** @type {(x: number) => BasslineFloat} */
export const float = x => new BasslineFloat(x)
/** @type {(s: string) => BasslineString} */
export const str = s => new BasslineString(s)
/** @type {(s: string) => BasslineSymbol} */
export const sym = s => new BasslineSymbol(s)
/** @type {(u8: Uint8Array) => BasslineBytes} */
export const bytes = u8 => new BasslineBytes(u8)
/** @type {(items: BasslineValue[]) => BasslineList} */
export const list = items => new BasslineList(items)
/** @type {(entries: [BasslineValue, BasslineValue][]) => BasslineDict} */
export const dict = entries => new BasslineDict(entries)
/** @type {(head: BasslineValue, ...fields: BasslineValue[]) => BasslineRecord} */
export const record = (head, ...fields) => new BasslineRecord([head, ...fields])
/** @type {(members: BasslineValue[]) => BasslineSet} */
export const set = members => new BasslineSet(members)

/**
 * @param {unknown} value
 * @returns {BasslineValue}
 */
export function toBassline(value) {
  if (value === undefined) {
    throw new TypeError('cannot convert undefined to Bassline value')
  }
  if (value instanceof BasslineValue) return value
  if (value === null) return nil()
  if (value === true) return bool(true)
  if (value === false) return bool(false)
  if (typeof value === 'bigint') return new BasslineInt(value)
  if (typeof value === 'number') {
    if (Number.isInteger(value)) return new BasslineInt(value)
    else return new BasslineFloat(value)
  }
  if (typeof value === 'string') return new BasslineString(value)
  if (typeof value === 'symbol') {
    if (!value.description)
      throw new TypeError('symbol must have a description')
    return new BasslineSymbol(value.description)
  }
  if (value instanceof Uint8Array) return new BasslineBytes(value)
  if (Array.isArray(value)) return new BasslineList(value.map(toBassline))
  if (value instanceof Map)
    return new BasslineDict(
      Array.from(value.entries()).map(([k, v]) => [
        toBassline(k),
        toBassline(v),
      ])
    )
  if (value instanceof Set)
    return new BasslineSet(Array.from(value).map(toBassline))

  if (typeof value === 'function' || typeof value === 'object') {
    if ('toBassline' in value && typeof value.toBassline === 'function') {
      const val = value.toBassline()
      if (val instanceof BasslineValue) return val
      throw new TypeError(
        'toBassline conversion did not return a Bassline value'
      )
    }
  }
  throw new TypeError('cannot convert value to Bassline value')
}

export class BasslineVisitor {
  /**
   *
   * @param {BasslineValue} aValue
   */
  visit(aValue) {
    return aValue.accept(this)
  }

  /**
   * @param {BasslineNil} aNil
   */
  visitNil(aNil) {
    return aNil
  }
  /**
   * @param {BasslineBool} aBool
   */
  visitBool(aBool) {
    return aBool
  }
  /**
   * @param {BasslineInt} anInt
   */
  visitInt(anInt) {
    return anInt
  }
  /**
   * @param {BasslineFloat} aFloat
   */
  visitFloat(aFloat) {
    return aFloat
  }
  /**
   * @param {BasslineString} aString
   */
  visitString(aString) {
    return aString
  }
  /**
   * @param {BasslineSymbol} aSymbol
   */
  visitSymbol(aSymbol) {
    return aSymbol
  }
  /**
   * @param {BasslineBytes} aBytes
   */
  visitBytes(aBytes) {
    return aBytes
  }
  /**
   * @param {BasslineList} aList
   */
  visitList(aList) {
    for (const item of aList.value) {
      this.visit(item)
    }
    return aList
  }
  /**
   * @param {BasslineDict} aDict
   */
  visitDict(aDict) {
    for (const [key, value] of aDict) {
      this.visit(key)
      this.visit(value)
    }
    return aDict
  }
  /**
   * @param {BasslineRecord} aRecord
   */
  visitRecord(aRecord) {
    this.visit(aRecord.head)
    for (const field of aRecord.fields) {
      this.visit(field)
    }
    return aRecord
  }
  /**
   * @param {BasslineSet} aSet
   */
  visitSet(aSet) {
    for (const member of aSet) {
      this.visit(member)
    }
    return aSet
  }
}

export class ActionableVisitor extends BasslineVisitor {
  constructor() {
    super()
    this.foundActionable = false
  }
  /**
   * @param {BasslineValue} aValue
   */
  visit(aValue) {
    if (aValue.actionable) {
      this.foundActionable = true
      return
    }
    return super.visit(aValue)
  }
}

export class CycleFreeVisitor extends BasslineVisitor {
  constructor() {
    super()
    this.seen = new Set()
    this.cycleDetected = false
  }
  /**
   * @param {BasslineValue} aValue
   */
  visit(aValue) {
    if (this.seen.has(aValue)) {
      this.cycleDetected = true
      return this
    }
    this.seen.add(aValue)
    return super.visit(aValue)
  }
}

/**
 * Whether a value carries the actionable bit anywhere in its tree
 * @param {BasslineValue} v
 * @returns {boolean}
 */
export function hasActionable(v) {
  const visitor = new ActionableVisitor()
  visitor.visit(v)
  return visitor.foundActionable
}

/** @type {(v: BasslineValue) => boolean} */
export const isData = v => (assertValue(v), !hasActionable(v))
/** @type {(v: BasslineValue) => boolean} */
export const isActionable = v => (assertValue(v), v.actionable)

/**
 * @param {BasslineValue} v
 */
export function cycleFree(v) {
  const visitor = new CycleFreeVisitor()
  visitor.visit(v)
  return !visitor.cycleDetected
}

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
/** @type {(b: number) => number} */
const tagOf = b => b & TAG_MASK
/** @type {(b: number) => boolean} */
const actionableOf = b => (b & ACTIONABLE) !== 0

const ENC = new TextEncoder()
const DEC = new TextDecoder('utf-8', { fatal: true })
const CANON_NAN = Uint8Array.of(0x7f, 0xf8, 0, 0, 0, 0, 0, 0)

/** @type {WeakMap<BasslineValue, Uint8Array>} */
const CE_CACHE = new WeakMap()
export class CEVisitor extends BasslineVisitor {
  /** @type {number[]} */
  sink = []
  /**
   * @param {number} b
   */
  byte(b) {
    this.sink.push(b & 0xff)
    return this
  }
  /**
   * @param {Uint8Array} u8
   */
  raw(u8) {
    for (let i = 0; i < u8.length; i++) this.sink.push(u8[i])
    return this
  }
  /**
   * @param {number} n
   */
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
  /**
   * @param {BasslineNil} aNil
   */
  visitNil(aNil) {
    this.byte(descriptor(NIL_PREFIX, aNil.actionable))
    return aNil
  }

  /**
   * @param {BasslineBool} aBool
   */
  visitBool(aBool) {
    const tag = aBool.value ? TRUE_PREFIX : FALSE_PREFIX
    this.byte(descriptor(tag, aBool.actionable))
    return aBool
  }
  /**
   *
   * @param {BasslineInt} anInt
   */
  visitInt(anInt) {
    const b = intToBytes(anInt.value)
    this.byte(descriptor(INT_PREFIX, anInt.actionable)).varint(b.length).raw(b)
    return anInt
  }
  /**
   * @param {BasslineFloat} aFloat
   */
  visitFloat(aFloat) {
    const dv = new DataView(new ArrayBuffer(8))
    dv.setFloat64(0, aFloat.value, false) // big-endian
    this.byte(descriptor(FLOAT_PREFIX, aFloat.actionable)).raw(
      new Uint8Array(dv.buffer)
    )
    return aFloat
  }
  /**
   * @param {BasslineString} aString
   */
  visitString(aString) {
    const u8 = ENC.encode(aString.value)
    this.byte(descriptor(STRING_PREFIX, aString.actionable))
      .varint(u8.length)
      .raw(u8)
    return aString
  }
  /**
   * @param {BasslineSymbol} aSymbol
   */
  visitSymbol(aSymbol) {
    const u8 = ENC.encode(aSymbol.value)
    this.byte(descriptor(SYMBOL_PREFIX, aSymbol.actionable))
      .varint(u8.length)
      .raw(u8)
    return aSymbol
  }
  /**
   * @param {BasslineBytes} aBytes
   */
  visitBytes(aBytes) {
    this.byte(descriptor(BYTES_PREFIX, aBytes.actionable))
      .varint(aBytes.value.length)
      .raw(aBytes.value)
    return aBytes
  }
  /**
   * @param {BasslineList} aList
   */
  visitList(aList) {
    this.frame(LIST_PREFIX, aList.actionable, body => {
      for (const c of aList.value) body.visit(c)
    })
    return aList
  }

  /**
   * @param {BasslineDict} aDict
   */
  visitDict(aDict) {
    const entries = Array.from(aDict.value.entries())
    entries.sort((a, b) => compareBytes(cachedCE(a[0]), cachedCE(b[0])))
    this.frame(DICT_PREFIX, aDict.actionable, body => {
      for (const [k, v] of entries) {
        body.visit(k)
        body.visit(v)
      }
    })
    return aDict
  }
  /**
   * @param {BasslineRecord} aRecord
   */
  visitRecord(aRecord) {
    const [head, ...fields] = aRecord.value
    this.frame(RECORD_PREFIX, aRecord.actionable, body => {
      body.visit(head)
      for (const f of fields) body.visit(f)
    })
    return aRecord
  }
  /**
   * @param {BasslineSet} aSet
   */
  visitSet(aSet) {
    const members = aSet.value
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

/**
 *
 * @param {BasslineValue} v
 */
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

/**
 * @param {BasslineValue} v The value to be encoded
 */
export function encode(v) {
  assertValue(v)
  return cachedCE(v).slice()
}

/**
 * @param {Uint8Array} bytes
 */
export function decode(bytes) {
  return BasslineDecoder.one(bytes)
}

/**
 * @param {Uint8Array} bytes
 */
export function decodeAll(bytes) {
  return BasslineDecoder.all(bytes)
}

/**
 *
 * @param {BasslineValue} v
 */
export function ceKey(v) {
  return Array.from(cachedCE(v))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
}

/**
 *
 * @param {Uint8Array} a
 * @param {Uint8Array} b
 */
function bytesEqual(a, b) {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

/**
 *
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
 * @param {BasslineValue} a
 * @param {BasslineValue} b
 * @returns {boolean} True if a and b are equal, false otherwise
 */
export function eq(a, b) {
  assertValue(a)
  assertValue(b)
  return bytesEqual(cachedCE(a), cachedCE(b))
}

export class BasslineDecoder {
  /** @type {number} */
  pos = 0
  /**
   * @param {Uint8Array} bytes
   */
  constructor(bytes) {
    this.bytes = bytes
    this.pos = 0
  }

  readByte() {
    if (this.pos >= this.bytes.length)
      throw new Error('unexpected end of input')
    return this.bytes[this.pos++]
  }

  /**
   * @param {number} n The number of bytes to read
   */
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

  /**
   * @param {Uint8Array} b
   */
  decodeUtf8(b) {
    return DEC.decode(b)
  }

  /**
   * @param {Uint8Array} b
   */
  decodeF64(b) {
    const dv = new DataView(b.buffer, b.byteOffset, 8)
    const x = dv.getFloat64(0, false)
    if (Number.isNaN(x) && !bytesEqual(b, CANON_NAN))
      throw new Error('non-canonical NaN')
    return x
  }

  /**
   * @param {Uint8Array} b
   */
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

  /**
   * @returns {BasslineValue}
   */
  decodeValue() {
    const desc = this.readByte()
    const tag = tagOf(desc)
    const actionable = actionableOf(desc)
    if (tag === BAD_PREFIX) throw new Error('bad prefix 0x0!')
    return this.decodeByTag(tag, actionable)
  }

  /**
   * @param {boolean} actionable
   * @returns {BasslineList}
   */
  decodeList(actionable) {
    const end = this.frameEnd()
    const items = []
    while (this.pos < end) items.push(this.decodeValue())
    if (this.pos !== end) throw new Error('extra bytes at end of list')
    return new BasslineList(items, actionable)
  }

  /**
   *
   * @param {boolean} actionable
   * @returns {BasslineDict}
   */
  decodeDict(actionable) {
    const end = this.frameEnd()
    /** @type {[BasslineValue, BasslineValue][]} */
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

  /**
   * @param {boolean} actionable
   * @returns {BasslineRecord}
   */
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

  /**
   *
   * @param {boolean} actionable
   * @returns {BasslineSet}
   */
  decodeSet(actionable) {
    const end = this.frameEnd()
    /** @type {BasslineValue[]} */
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
   * @returns {BasslineValue}
   */
  static one(input) {
    const dec = new BasslineDecoder(input)
    const val = dec.decodeValue()
    if (dec.pos !== input.length) throw new Error('extra bytes at end of input')
    return val
  }

  /**
   * @param {Uint8Array} input
   * @returns {BasslineValue[]}
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
