// Reference implementation of the Bassline Data Model
// Each value type is implemented as a subclass of BasslineValue
// Each value has a single canonical encoding which determines it's identity
// There are 7 atomic value types:
// null, true, false, int, float, string, symbol
// Alongside 4 frame value types:
// list, dict, record, set
// 
// the function eq performs comparison by canonical encoding bytes
// whereas equal performs semantic comparison, rejecting comparisons
// between non data values

const ENC = new TextEncoder()
const DEC = new TextDecoder('utf-8', { fatal: true })
const LATIN1 = new TextDecoder('latin1')

const CANON_NAN = Uint8Array.of(0x7f, 0xf8, 0, 0, 0, 0, 0, 0)

/** @returns {x is BasslineValue} whether x is a Bassline value. */
export const isValue = x => x instanceof BasslineValue

function assertValue(x) {
  if (!isValue(x)) throw new TypeError('expected a Bassline value')
}

export const NULL_PREFIX = 0x00
export const FALSE_PREFIX = 0x01
export const TRUE_PREFIX = 0x02
export const INT_PREFIX = 0x03
export const FLOAT_PREFIX = 0x04
export const STRING_PREFIX = 0x05
export const SYMBOL_PREFIX = 0x06
export const BYTES_PREFIX = 0x07
export const LIST_PREFIX = 0x08
export const DICT_PREFIX = 0x09
export const RECORD_PREFIX = 0x0a
export const SET_PREFIX = 0x0b
export const MARK_PREFIX = 0x0c

// ---------------------------------------------------------------------------
// Byte sink — a minimal append-only buffer used by encoding.
// ---------------------------------------------------------------------------

class ByteSink {
  constructor() {
    /** @type {number[]} */
    this.out = []
  }

  byte(b) {
    this.out.push(b & 0xff)
  }

  raw(u8) {
    for (let i = 0; i < u8.length; i++) this.out.push(u8[i])
  }

  /** Unsigned LEB128, minimal form (§7.2). `n` is a non-negative integer. */
  varint(n) {
    let v = n
    for (;;) {
      const b = v % 128
      v = Math.floor(v / 128)
      if (v > 0) {
        this.out.push(b | 0x80)
      } else {
        this.out.push(b)
        return
      }
    }
  }

  toUint8Array() {
    return Uint8Array.from(this.out)
  }
}

/** Minimal two's-complement big-endian bytes for a BigInt (§7.2). */
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

export class BasslineValue {
  marked = false
  _baseData = true
  constructor(value) {
    if (new.target === BasslineValue)
      throw new Error('BasslineValue is abstract')
    this.value = value
  }

  get isData() {
    return !this.marked && this._baseData
  }

  mark() {
    return this.marked ? this : this.clone(true)
  }

  open() {
    if (!this.marked) throw new Error('open of an unmarked value')
    return this.clone(false)
  }

  clone(marked = false) {
    const twin = Object.create(Object.getPrototypeOf(this))
    Object.assign(twin, this)
    twin.marked = marked
    return Object.freeze(twin)
  }

  /** Append this value's CE to a sink with the mark if present */
  writeCE(sink) {
    if (this.marked) sink.byte(MARK_PREFIX)
    this.encodeBody(sink)
  }

  encodeBody(_sink) {
    throw new Error('abstract')
  }
}

export class BasslineNull extends BasslineValue {
  constructor() {
    super(null)
    Object.freeze(this)
  }

  encodeBody(sink) {
    sink.byte(NULL_PREFIX)
  }
}

export class BasslineBool extends BasslineValue {
  constructor(value) {
    super(Boolean(value))
    Object.freeze(this)
  }

  encodeBody(sink) {
    sink.byte(this.value ? TRUE_PREFIX : FALSE_PREFIX)
  }
}

export class BasslineInt extends BasslineValue {
  constructor(value) {
    if (typeof value !== 'bigint') throw new TypeError('int expects a BigInt')
    super(value)
    Object.freeze(this)
  }

  encodeBody(sink) {
    sink.byte(INT_PREFIX)
    const b = intToBytes(this.value)
    sink.varint(b.length)
    sink.raw(b)
  }
}

export class BasslineFloat extends BasslineValue {
  constructor(value) {
    if (typeof value !== 'number') throw new TypeError('float expects a Number')
    super(value)
    Object.freeze(this)
  }

  encodeBody(sink) {
    sink.byte(FLOAT_PREFIX)
    const dv = new DataView(new ArrayBuffer(8))
    dv.setFloat64(0, this.value, false)
    sink.raw(new Uint8Array(dv.buffer))
  }
}

/** Reject lone surrogates: they would not round-trip through UTF-8 (§3). */
function assertWellFormed(s) {
  if(!s.isWellFormed()) throw new Error('string is not well-formed')
}

export class BasslineString extends BasslineValue {
  constructor(value) {
    if (typeof value !== 'string') throw new TypeError('str expects a string')
    assertWellFormed(value)
    super(value)
    Object.freeze(this)
  }

  encodeBody(sink) {
    const u8 = ENC.encode(this.value)
    sink.byte(STRING_PREFIX)
    sink.varint(u8.length)
    sink.raw(u8)
  }
}

export class BasslineSymbol extends BasslineValue {
  constructor(value) {
    if (typeof value !== 'string') throw new TypeError('symbol expects a string')
    assertWellFormed(value)
    super(value)
    Object.freeze(this)
  }

  encodeBody(sink) {
    const u8 = ENC.encode(this.value)
    sink.byte(SYMBOL_PREFIX)
    sink.varint(u8.length)
    sink.raw(u8)
  }
}

export class BasslineBytes extends BasslineValue {
  constructor(value) {
    if (!(value instanceof Uint8Array))
      throw new TypeError('bytes expects a Uint8Array')
    super(value.slice())
    Object.freeze(this)
  }

  encodeBody(sink) {
    sink.byte(BYTES_PREFIX)
    sink.varint(this.value.length)
    sink.raw(this.value)
  }
}

export class BasslineList extends BasslineValue {
  constructor(items) {
    if (!Array.isArray(items) || !items.every(isValue)) {
      throw new TypeError('list expects an array of Bassline values')
    }
    const value = Object.freeze(items.slice())
    super(value)
    this._baseData = this.value.every(c => c.isData)
    Object.freeze(this)
  }

  encodeBody(sink) {
    sink.byte(LIST_PREFIX)
    sink.varint(this.value.length)
    for (const c of this.value) c.writeCE(sink)
  }
}

export class BasslineDict extends BasslineValue {
  constructor(entries) {
    const seenKeys = new Set()
    const prepared = entries.map(([key, val]) => {
      if (!isValue(key) || !isValue(val))
        throw new TypeError('dict entry must be [Value, Value]')
      if (!key.isData) throw new Error('dict key must be Data (no mark)')
      const ck = ceKey(key)
      if (seenKeys.has(ck)) throw new Error('duplicate dict key')
      seenKeys.add(ck)
      return { key, val, ck }
    })
    prepared.sort((a, b) => (a.ck < b.ck ? -1 : a.ck > b.ck ? 1 : 0))
    const value = Object.freeze(prepared.map(p => Object.freeze([p.key, p.val])))
    super(value)
    this._baseData = prepared.every(p => p.val.isData)
    Object.freeze(this)
  }

  encodeBody(sink) {
    sink.byte(DICT_PREFIX)
    sink.varint(this.value.length)
    for (const [key, val] of this.value) {
      key.writeCE(sink)
      val.writeCE(sink)
    }
  }

  get(key)  {
    for (const [k, v] of this.value) if (eq(k, key)) return v
    return undefined
  }
}

export class BasslineRecord extends BasslineValue {
  constructor(head, fields) {
    if (!isValue(head))
      throw new TypeError('record head must be a Bassline value')
    if (!Array.isArray(fields) || !fields.every(isValue)) {
      throw new TypeError('record fields must be an array of Bassline values')
    }
    const value = {head, fields: Object.freeze(fields.slice())}
    super(value)
    this._baseData = head.isData && value.fields.every(f => f.isData)
    Object.freeze(this)
  }

  encodeBody(sink) {
    const {fields, head} = this.value
    sink.byte(RECORD_PREFIX)
    head.writeCE(sink)
    sink.varint(fields.length)
    for (const f of fields) f.writeCE(sink)
  }
}

export class BasslineSet extends BasslineValue {
  constructor(members) {
    const seen = new Set()
    const prepared = members.map(m => {
      if (!isValue(m))
        throw new TypeError('set member must be a Bassline value')
      if (!m.isData) throw new Error('set member must be Data (no mark)') // §4
      const ck = ceKey(m)
      if (seen.has(ck)) throw new Error('duplicate set member')
      seen.add(ck)
      return { m, ck }
    })
    prepared.sort((a, b) => (a.ck < b.ck ? -1 : a.ck > b.ck ? 1 : 0))
    const value = Object.freeze(prepared.map(p => p.m))
    super(value)
    this._baseData = value.every(m => m.isData)
    Object.freeze(this)
  }

  encodeBody(sink) {
    sink.byte(SET_PREFIX)
    sink.varint(this.value.length)
    for (const m of this.value) m.writeCE(sink)
  }

  has(member) {
    return this.value.some(m => eq(m, member))
  }
}

// ================ singletons ================
const NULL = new BasslineNull()
const TRUE = new BasslineBool(true)
const FALSE = new BasslineBool(false)

// ================ factories ================
export const nul = () => NULL
export const bool = b => (b ? TRUE : FALSE)
export const int = n => new BasslineInt(n)
export const float = x => new BasslineFloat(x)
export const str = s => new BasslineString(s)
export const sym = s => new BasslineSymbol(s)
export const bytes = u8 => new BasslineBytes(u8)
export const list = items => new BasslineList(items)
export const dict = entries => new BasslineDict(entries)
export const record = (head, fields = []) => new BasslineRecord(head, fields)
export const set = members => new BasslineSet(members)

export const mark = v => {
  assertValue(v)
  return v.mark()
}
export const open = v => {
  assertValue(v)
  return v.open()
}
export const isData = v => (assertValue(v), v.isData)
export const isMarked = v => (assertValue(v), v.marked)

// ================ Canonical Encoding ================

/** @type {WeakMap<BasslineValue, Uint8Array>} */
const CE_CACHE = new WeakMap()

/** Performs a memoized canonical encoding of a value */
export function encode(v) {
  assertValue(v)
  let b = CE_CACHE.get(v)
  if (!b) {
    const sink = new ByteSink()
    v.writeCE(sink)
    b = sink.toUint8Array()
    CE_CACHE.set(v, b)
  }
  return b
}

/** CE bytes as a latin1 string: a value identity usable as a Map/Set key. */
export function ceKey(v) {
  return LATIN1.decode(encode(v))
}

function bytesEqual(a, b) {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

/** Lexicographic over bytes, shorter prefix first. */
function compareBytes(a, b) {
  const n = Math.min(a.length, b.length)
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] - b[i]
  return a.length - b.length
}

export function eq(a, b) {
  return bytesEqual(encode(a), encode(b))
}

export function equal(a, b) {
  assertValue(a)
  assertValue(b)
  if (!a.isData || !b.isData) throw new Error('equal? is undefined for non-data values')
  return eq(a, b)
}

// ================ Decoding ================
// This stuff uses a cursor over bytes with strict validation
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

/** Unsigned LEB128, rejecting non-minimal encodings. */
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

/** Minimal two's-complement big-endian bytes -> BigInt, validating minimality. */
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

function decodeValue(cur) {
  const tag = readByte(cur)
  switch (tag) {
    case NULL_PREFIX:
      return NULL
    case FALSE_PREFIX:
      return FALSE
    case TRUE_PREFIX:
      return TRUE
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
    case LIST_PREFIX: {
      return decodeList(cur)
    }
    case DICT_PREFIX:
      return decodeDict(cur)
    case RECORD_PREFIX:
      return decodeRecord(cur)
    case SET_PREFIX:
      return decodeSet(cur)
    case MARK_PREFIX: {
      if (cur.pos < cur.bytes.length && cur.bytes[cur.pos] === MARK_PREFIX) {
        throw new Error('doubled mark prefix')
      }
      return decodeValue(cur).mark()
    }
    default:
      throw new Error('unknown tag 0x' + tag.toString(16))
  }
}

function decodeList(cur) {
  const n = readVarint(cur)
  const items = []
  for (let i = 0; i < n; i++) items.push(decodeValue(cur))
  return list(items)
}

function decodeRecord(cur) {
  const head = decodeValue(cur)
  const n = readVarint(cur)
  const fields = []
  for (let i = 0; i < n; i++) fields.push(decodeValue(cur))
  return record(head, fields)
}

function decodeDict(cur) {
  const n = readVarint(cur)
  const entries = []
  let prevKeyCE = null
  for (let i = 0; i < n; i++) {
    const start = cur.pos
    const key = decodeValue(cur)
    const keyCE = cur.bytes.subarray(start, cur.pos)
    if (!key.isData) throw new Error('non-Data dict key')
    if (prevKeyCE !== null) {
      const c = compareBytes(prevKeyCE, keyCE)
      if (c > 0) throw new Error('dict keys out of order')
      if (c === 0) throw new Error('duplicate dict key')
    }
    prevKeyCE = keyCE
    entries.push([key, decodeValue(cur)])
  }
  return dict(entries)
}

function decodeSet(cur) {
  const n = readVarint(cur)
  const members = []
  let prevCE = null
  for (let i = 0; i < n; i++) {
    const start = cur.pos
    const m = decodeValue(cur)
    const ce = cur.bytes.subarray(start, cur.pos)
    if (!m.isData) throw new Error('non-Data set member')
    if (prevCE !== null) {
      const c = compareBytes(prevCE, ce)
      if (c > 0) throw new Error('set members out of order')
      if (c === 0) throw new Error('duplicate set member')
    }
    prevCE = ce
    members.push(m)
  }
  return set(members)
}

export function decode(input) {
  const b = input instanceof Uint8Array ? input : Uint8Array.from(input)
  const cur = { bytes: b, pos: 0 }
  const v = decodeValue(cur)
  if (cur.pos !== b.length) throw new Error('trailing garbage')
  return v
}