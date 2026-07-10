// @ts-check

/**
 * Note! This is not a thorough or complete implementation rn.
 * Too bad! I'll fix this up later fr.
 * @param {unknown} x
 * @returns {x is Value}
 */
export function isValue(x) {
  if (typeof x !== 'object' || x === null) return false
  const hasProps = 'kind' in x && 'actionable' in x && 'value' in x
  if (!hasProps) return false
  switch (x.kind) {
    case 'nil':
    case 'int':
    case 'string':
    case 'symbol':
    case 'bytes':
    case 'list':
    case 'record':
    case 'dict':
    case 'set':
      return true
    default:
      return false
  }
}

/**
 * @param {Value} x
 * @returns {x is Values[AtomKind]}
 */
export function isAtom(x) {
  assertValue(x, 'isAtom requires a Bassline value!')
  switch (x.kind) {
    case 'string':
    case 'symbol':
    case 'nil':
    case 'int':
    case 'bytes':
      return true
    default:
      return false
  }
}

/**
 * @param {Value} x
 * @returns {x is Values[FrameKind]}
 */
export function isFrame(x) {
  assertValue(x, 'isFrame requires a BasslineValue!')
  switch (x.kind) {
    case 'list':
    case 'record':
    case 'dict':
    case 'set':
      return true
    default:
      return false
  }
}

/**
 * @param {unknown} x
 * @param {string} [msg] - The error message to throw if x is not a Bassline value
 * @throws {TypeError} if x is not a Bassline value.
 * @returns {asserts x is Value}
 */
export function assertValue(x, msg = 'expected a Bassline value') {
  if (!isValue(x)) throw new TypeError(msg)
}

/**
 * @template {FrameKind | AtomKind} K
 * @template T
 * @typedef {{
 * readonly kind: K
 * readonly value: T
 * readonly actionable: boolean
 * }} ValueType
 */

/**
 * @typedef {{
 * readonly kind: "list"
 * readonly actionable: boolean
 * readonly value: Value[]
 * }} BList
 */

/**
 * @typedef {{
 * readonly kind: "record"
 * readonly actionable: boolean
 * readonly value: [Value, ...Value[]]
 * }} BRecord
 */

/**
 * @typedef {{
 * readonly kind: "dict"
 * readonly actionable: boolean
 * readonly value: Array<[Value, Value]>
 * }} BDict
 */

/**
 * @typedef {{
 * readonly kind: "set"
 * readonly actionable: boolean
 * readonly value: Value[]
 * }} BSet
 */

/**
 * @typedef {ValueType<"nil", null>} BNil
 * @typedef {ValueType<"int", bigint>} BInt
 * @typedef {ValueType<"string", string>} BString
 * @typedef {ValueType<"symbol", string>} BSymbol
 * @typedef {ValueType<"bytes", Uint8Array>} BBytes
 */

/**
 * @typedef {{
 * nil: BNil,
 * int: BInt,
 * string: BString,
 * symbol: BSymbol,
 * bytes: BBytes,
 * list: BList
 * record: BRecord
 * dict: BDict
 * set: BSet
 * }} Values
 */

/** @typedef {Values[keyof Values]} Value */

/**
 * @typedef {"bytes" | "int" | "nil" | "string" | "symbol"} AtomKind
 * @typedef {"list" | "record" | "dict" | "set"} FrameKind
 * @typedef {keyof Values} ValueKind
 */

/**
 * @typedef {Values[FrameKind]} Frame
 * @typedef {Values[AtomKind]} Atom
 */
