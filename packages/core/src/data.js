// Reference implementation of the Bassline Data Model
// Each value type is implemented as a subclass of BasslineValue
// Each value has a single canonical encoding which determines it's identity
// There are 7 atomic value types:
// NIL, true, false, int, float, string, symbol
// Alongside 4 frame value types:
// list, dict, record, set

/**
 * @param x
 * @returns {x is BasslineValue} whether x is a Bassline value.
 */
export const isValue = x => x instanceof BasslineValue

/**
 * @param {unknown} x
 * @throws {TypeError} if x is not a Bassline value.
 * @returns {x is BasslineValue}
 */
export function assertValue(x) {
  if (!isValue(x)) throw new TypeError('expected a Bassline value')
  return x
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

  accept(_aVisitor) {
    throw new Error('abstract')
  }

  copy(_actionable) {
    throw new Error('abstract')
  }

  encode() {
    return encode(this)
  }

  ceKey() {
    return ceKey(this)
  }

  eq(other) {
    return eq(this, other)
  }

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
  accept(aVisitor) {
    return aVisitor.visitNil(this)
  }
}

export class BasslineBool extends BasslineValue {
  #value
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
  accept(aVisitor) {
    return aVisitor.visitBool(this)
  }
}

export class BasslineInt extends BasslineValue {
  #value
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

  accept(aVisitor) {
    return aVisitor.visitInt(this)
  }
  copy(actionable = this.actionable) {
    return new BasslineInt(this.value, actionable)
  }
}

export class BasslineFloat extends BasslineValue {
  #value
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

  accept(aVisitor) {
    return aVisitor.visitFloat(this)
  }
  copy(actionable = this.actionable) {
    return new BasslineFloat(this.value, actionable)
  }
}

export class BasslineString extends BasslineValue {
  #value
  constructor(value, actionable = false) {
    if (typeof value !== 'string') throw new TypeError('str expects a string')
    if (!value.isWellFormed()) throw new Error('string is not well-formed')
    super(actionable)
    this.#value = value
  }

  get value() {
    return this.#value
  }

  accept(aVisitor) {
    return aVisitor.visitString(this)
  }

  copy(actionable = this.actionable) {
    return new BasslineString(this.value, actionable)
  }
}

export class BasslineSymbol extends BasslineValue {
  #value
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

  accept(aVisitor) {
    return aVisitor.visitSymbol(this)
  }
  copy(actionable = this.actionable) {
    return new BasslineSymbol(this.value, actionable)
  }
}

export class BasslineBytes extends BasslineValue {
  #value
  constructor(value, actionable = false) {
    if (!(value instanceof Uint8Array))
      throw new TypeError('bytes expects a Uint8Array')
    super(actionable)
    this.#value = value.slice()
  }

  get value() {
    return this.#value.slice()
  }

  accept(aVisitor) {
    return aVisitor.visitBytes(this)
  }

  copy(actionable = this.actionable) {
    return new BasslineBytes(this.value, actionable)
  }
}

export class BasslineList extends BasslineValue {
  #value
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

  at(index) {
    if (typeof index !== 'number') throw new TypeError('index must be a number')
    return this.#value.at(index)
  }

  length() {
    return this.#value.length
  }

  append(...items) {
    return new BasslineList([...this.#value, ...items], this.actionable)
  }

  map(callback) {
    return new BasslineList(this.#value.map(callback), this.actionable)
  }

  filter(callback) {
    return new BasslineList(this.#value.filter(callback), this.actionable)
  }

  get value() {
    return this.#value.slice()
  }

  *[Symbol.iterator]() {
    yield* this.value
  }

  accept(aVisitor) {
    return aVisitor.visitList(this)
  }

  copy(actionable = this.actionable) {
    return new BasslineList(this.value, actionable)
  }
}

export class BasslineDict extends BasslineValue {
  #value
  #cache
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

  get value() {
    const result = new Map()
    for (const [key, val] of this.#value) {
      const origKey = this.#cache.get(key)
      if (!origKey) throw new Error('rebuild: missing original key in cache')
      result.set(origKey, val)
    }
    return result
  }

  map(callback) {
    return new BasslineDict(
      Array.from(this.value).map(callback),
      this.actionable
    )
  }

  filter(callback) {
    return new BasslineDict(
      Array.from(this.value).filter(callback),
      this.actionable
    )
  }

  append(...entries) {
    return new BasslineDict([...this.value, ...entries], this.actionable)
  }

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

  set(k, v) {
    return this.append([k, v])
  }

  get(k) {
    if (!isValue(k)) throw new TypeError('dict key must be a Bassline value')
    return this.#value.get(k.ceKey())
  }

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

  accept(aVisitor) {
    return aVisitor.visitDict(this)
  }

  copy(actionable) {
    return new BasslineDict([...this.value], actionable)
  }
}

export class BasslineRecord extends BasslineValue {
  #value
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

  map(callback) {
    return new BasslineRecord(this.value.map(callback), this.actionable)
  }

  filter(callback) {
    return new BasslineRecord(this.value.filter(callback), this.actionable)
  }

  accept(aVisitor) {
    return aVisitor.visitRecord(this)
  }

  copy(actionable) {
    return new BasslineRecord(this.value, actionable)
  }
}

export class BasslineSet extends BasslineValue {
  #value
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

  get value() {
    return Array.from(this.#value.values())
  }

  map(callback) {
    const newMembers = this.value.map(m => callback(m))
    return new BasslineSet(newMembers, this.actionable)
  }

  filter(callback) {
    const newMembers = this.value.filter(m => callback(m))
    return new BasslineSet(newMembers, this.actionable)
  }

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

  delete(...members) {
    const s = new Map(this.#value)
    for (const m of members) {
      if (!isValue(m))
        throw new TypeError('set member must be a Bassline value')
      s.delete(m.ceKey())
    }
    return new BasslineSet(Array.from(s.values()), this.actionable)
  }

  add(m) {
    return this.append(m)
  }

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

  accept(aVisitor) {
    return aVisitor.visitSet(this)
  }

  copy(actionable = this.actionable) {
    return new BasslineSet(this.value, actionable)
  }
}

// ================ factories ================
export const nil = () => new BasslineNil()
export const bool = b => new BasslineBool(b)
export const int = n => new BasslineInt(n)
export const float = x => new BasslineFloat(x)
export const str = s => new BasslineString(s)
export const sym = s => new BasslineSymbol(s)
export const bytes = u8 => new BasslineBytes(u8)
export const list = items => new BasslineList(items)
export const dict = entries => new BasslineDict(entries)
export const record = (head, ...fields) => new BasslineRecord([head, ...fields])
export const set = members => new BasslineSet(members)

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
  if (value instanceof Array) return new BasslineList(value.map(toBassline))
  if (value instanceof Map)
    return new BasslineDict(
      Array.from(value.entries()).map(([k, v]) => [
        toBassline(k),
        toBassline(v),
      ])
    )
  if (value instanceof Set)
    return new BasslineSet(Array.from(value).map(toBassline))
  const conversion = value?.toBassline
  if (typeof conversion === 'function') {
    const value = conversion.call(value)
    if (value instanceof BasslineValue) return value
    throw new TypeError('toBassline conversion did not return a Bassline value')
  }
  throw new TypeError('cannot convert value to Bassline value')
}

export class BasslineVisitor {
  visit(aValue) {
    return aValue.accept(this)
  }
  visitNil(aNil) {
    return aNil
  }
  visitBool(aBool) {
    return aBool
  }
  visitInt(anInt) {
    return anInt
  }
  visitFloat(aFloat) {
    return aFloat
  }
  visitString(aString) {
    return aString
  }
  visitSymbol(aSymbol) {
    return aSymbol
  }
  visitBytes(aBytes) {
    return aBytes
  }
  visitList(aList) {
    for (const item of aList.value) {
      this.visit(item)
    }
    return aList
  }
  visitDict(aDict) {
    for (const [key, value] of aDict) {
      this.visit(key)
      this.visit(value)
    }
    return aDict
  }
  visitRecord(aRecord) {
    this.visit(aRecord.head)
    for (const field of aRecord.fields) {
      this.visit(field)
    }
    return aRecord
  }
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
  visit(aValue) {
    if (aValue.actionable) {
      this.foundActionable = true
      return this
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
 * @param v
 * @returns {boolean}
 */
export function hasActionable(v) {
  const visitor = new ActionableVisitor()
  visitor.visit(v)
  return visitor.foundActionable
}

export const isData = v => (assertValue(v), !hasActionable(v))
export const isActionable = v => (assertValue(v), v.actionable)

/**
 *
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
const descriptor = (tag, actionable) => (actionable ? tag | ACTIONABLE : tag)
const tagOf = b => b & TAG_MASK
const actionableOf = b => (b & ACTIONABLE) !== 0

const ENC = new TextEncoder()
const DEC = new TextDecoder('utf-8', { fatal: true })
const CANON_NAN = Uint8Array.of(0x7f, 0xf8, 0, 0, 0, 0, 0, 0)

/** @type {WeakMap<BasslineValue, Uint8Array>} */
const CE_CACHE = new WeakMap()
export class CEVisitor extends BasslineVisitor {
  sink = []
  byte(b) {
    this.sink.push(b & 0xff)
    return this
  }
  raw(u8) {
    for (let i = 0; i < u8.length; i++) this.sink.push(u8[i])
    return this
  }
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
  // A frame is its descriptor, a byte-length varint, then the body bytes.
  // The body is built in a sub-visitor so its length is known before writing.
  frame(tag, actionable, emit) {
    const body = new CEVisitor()
    emit(body)
    this.byte(descriptor(tag, actionable)).varint(body.sink.length)
    for (const b of body.sink) this.sink.push(b)
    return this
  }
  visitNil(aNil) {
    this.byte(descriptor(NIL_PREFIX, aNil.actionable))
  }
  visitBool(aBool) {
    const tag = aBool.value ? TRUE_PREFIX : FALSE_PREFIX
    this.byte(descriptor(tag, aBool.actionable))
  }
  visitInt(anInt) {
    const b = intToBytes(anInt.value)
    this.byte(descriptor(INT_PREFIX, anInt.actionable)).varint(b.length).raw(b)
  }
  visitFloat(aFloat) {
    const dv = new DataView(new ArrayBuffer(8))
    dv.setFloat64(0, aFloat.value, false) // big-endian
    this.byte(descriptor(FLOAT_PREFIX, aFloat.actionable)).raw(
      new Uint8Array(dv.buffer)
    )
  }
  visitString(aString) {
    const u8 = ENC.encode(aString.value)
    this.byte(descriptor(STRING_PREFIX, aString.actionable))
      .varint(u8.length)
      .raw(u8)
  }
  visitSymbol(aSymbol) {
    const u8 = ENC.encode(aSymbol.value)
    this.byte(descriptor(SYMBOL_PREFIX, aSymbol.actionable))
      .varint(u8.length)
      .raw(u8)
  }
  visitBytes(aBytes) {
    this.byte(descriptor(BYTES_PREFIX, aBytes.actionable))
      .varint(aBytes.value.length)
      .raw(aBytes.value)
  }
  visitList(aList) {
    this.frame(LIST_PREFIX, aList.actionable, body => {
      for (const c of aList.value) body.visit(c)
    })
  }
  visitDict(aDict) {
    const entries = []
    for (const [k, v] of aDict) {
      entries.push([k, v])
    }
    entries.sort((a, b) => compareBytes(cachedCE(a[0]), cachedCE(b[0])))
    this.frame(DICT_PREFIX, aDict.actionable, body => {
      for (const [k, v] of entries) {
        body.visit(k)
        body.visit(v)
      }
    })
  }
  visitRecord(aRecord) {
    const [head, ...fields] = aRecord.value
    this.frame(RECORD_PREFIX, aRecord.actionable, body => {
      body.visit(head)
      for (const f of fields) body.visit(f)
    })
  }
  visitSet(aSet) {
    const members = [...aSet.value].sort((a, b) =>
      compareBytes(cachedCE(a), cachedCE(b))
    )
    this.frame(SET_PREFIX, aSet.actionable, body => {
      for (const m of members) body.visit(m)
    })
  }
}

/**
 * Minimal two's-complement big-endian bytes
 * @param n
 */
function intToBytes(n) {
  if (n === 0n) return Uint8Array.of(0)
  let width = 1
  for (;;) {
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

export function encode(v) {
  assertValue(v)
  return cachedCE(v).slice()
}

export function ceKey(v) {
  return Array.from(cachedCE(v))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
}

function bytesEqual(a, b) {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

function compareBytes(a, b) {
  const n = Math.min(a.length, b.length)
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] - b[i]
  return a.length - b.length
}

export function eq(a, b) {
  assertValue(a)
  assertValue(b)
  return bytesEqual(cachedCE(a), cachedCE(b))
}

// ================ Decoding ================
function readByte(cur) {
  if (cur.pos >= cur.bytes.length) throw new Error('unexpected end of input')
  return cur.bytes[cur.pos++]
}

function readBytes(cur, n) {
  if (cur.pos + n > cur.bytes.length) throw new Error('unexpected end of input')
  const b = cur.bytes.subarray(cur.pos, cur.pos + n)
  cur.pos += n
  return b
}

/**
 * Unsigned LEB128, rejecting non-minimal encodings.
 * @param cur
 */
function readVarint(cur) {
  let result = 0
  let mul = 1
  let count = 0
  for (;;) {
    const b = readByte(cur)
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
 * Minimal two's-complement big-endian bytes -> BigInt
 * @param b
 */
function bytesToInt(b) {
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

function decodeF64(b) {
  const dv = new DataView(b.buffer, b.byteOffset, 8)
  const x = dv.getFloat64(0, false)
  if (Number.isNaN(x) && !bytesEqual(b, CANON_NAN))
    throw new Error('non-canonical NaN')
  return x
}

function decodeUtf8(b) {
  try {
    return DEC.decode(b)
  } catch {
    throw new Error('ill-formed UTF-8')
  }
}

function decodeByTag(cur, tag) {
  switch (tag) {
    case NIL_PREFIX:
      return nil()
    case FALSE_PREFIX:
      return bool(false)
    case TRUE_PREFIX:
      return bool(true)
    case INT_PREFIX: {
      const len = readVarint(cur)
      if (len === 0) throw new Error('zero-length integer')
      return int(bytesToInt(readBytes(cur, len)))
    }
    case FLOAT_PREFIX:
      return float(decodeF64(readBytes(cur, 8)))
    case STRING_PREFIX:
      return str(decodeUtf8(readBytes(cur, readVarint(cur))))
    case SYMBOL_PREFIX:
      return sym(decodeUtf8(readBytes(cur, readVarint(cur))))
    case BYTES_PREFIX:
      return bytes(readBytes(cur, readVarint(cur)))
    case LIST_PREFIX:
      return decodeList(cur)
    case DICT_PREFIX:
      return decodeDict(cur)
    case RECORD_PREFIX:
      return decodeRecord(cur)
    case SET_PREFIX:
      return decodeSet(cur)
    default:
      throw new Error('unknown tag 0x' + tag.toString(16))
  }
}

function decodeValue(cur) {
  const desc = readByte(cur)
  const tag = tagOf(desc)
  if (tag === BAD_PREFIX) throw new Error('decoded an bad prefix 0x0')
  const v = decodeByTag(cur, tag)
  return actionableOf(desc) ? v.toActionable() : v
}

/**
 * Read a frame's byte-length varint and return its end offset.
 * @param cur
 */
function frameEnd(cur) {
  const len = readVarint(cur)
  const end = cur.pos + len
  if (end > cur.bytes.length) throw new Error('frame length exceeds input')
  return end
}

function decodeList(cur) {
  const end = frameEnd(cur)
  const items = []
  while (cur.pos < end) items.push(decodeValue(cur))
  if (cur.pos !== end) throw new Error('list length mismatch')
  return list(items)
}

function decodeRecord(cur) {
  const end = frameEnd(cur)
  if (cur.pos >= end) throw new Error('record needs a head')
  const head = decodeValue(cur)
  const fields = []
  while (cur.pos < end) fields.push(decodeValue(cur))
  if (cur.pos !== end) throw new Error('record length mismatch')
  return record(head, ...fields)
}

function decodeDict(cur) {
  const end = frameEnd(cur)
  const entries = []
  let prevKeyCE = null
  while (cur.pos < end) {
    const start = cur.pos
    const key = decodeValue(cur)
    const keyCE = cur.bytes.subarray(start, cur.pos)
    if (prevKeyCE !== null) {
      const c = compareBytes(prevKeyCE, keyCE)
      if (c > 0) throw new Error('dict keys out of order')
      if (c === 0) throw new Error('duplicate dict key')
    }
    prevKeyCE = keyCE
    if (cur.pos >= end) throw new Error('dict key missing its value')
    entries.push([key, decodeValue(cur)])
  }
  if (cur.pos !== end) throw new Error('dict length mismatch')
  return dict(entries)
}

function decodeSet(cur) {
  const end = frameEnd(cur)
  const members = []
  let prevCE = null
  while (cur.pos < end) {
    const start = cur.pos
    const m = decodeValue(cur)
    const ce = cur.bytes.subarray(start, cur.pos)
    if (prevCE !== null) {
      const c = compareBytes(prevCE, ce)
      if (c > 0) throw new Error('set members out of order')
      if (c === 0) throw new Error('duplicate set member')
    }
    prevCE = ce
    members.push(m)
  }
  if (cur.pos !== end) throw new Error('set length mismatch')
  return set(members)
}

export function decode(input) {
  const b = input instanceof Uint8Array ? input : Uint8Array.from(input)
  const cur = { bytes: b, pos: 0 }
  const v = decodeValue(cur)
  if (cur.pos !== b.length) throw new Error('trailing garbage')
  return v
}

/**
 * Decode a sequence of concatenated values until the bytes run out.
 *  CE is prefix-free, so each value is self-delimiting.
 * @param input
 */
export function decodeAll(input) {
  const b = input instanceof Uint8Array ? input : Uint8Array.from(input)
  const cur = { bytes: b, pos: 0 }
  const values = []
  while (cur.pos < b.length) values.push(decodeValue(cur))
  return values
}
