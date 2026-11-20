// @ts-check

// The JSON dialect: a lossless, kind-tagged encoding of a value as JSON, and
// back. A port of the Nim `lib/json.nim`. JSON is a foreign format — it only
// carries values, it is never canonical (a value's sole identity is its CE
// bytes), and a reading refuses what it cannot hold rather than coercing.
//
// Each value is a JSON object `{ "kind": <name>, "mark"?: true, "value": … }`:
//
//   nil        no "value"
//   number     a JSON number spelled in digits, at any width — `fromJSON`
//              recovers it losslessly through the parser's source access and
//              `toJSON` writes a past-2^53 integer with `JSON.rawJSON`
//   text       a JSON string
//   symbol     a JSON string
//   bytes      a "0x…" hex string
//   list       an array of value objects
//   record     an array of value objects, head first, at least one
//   dict       an array of [key, value] pairs, each a two-element array
//   set        an array of value objects
//
// Reading accepts dict and set members in any order and refuses duplicates.
// It also refuses an unknown key on the object — a stricter reading than the
// Nim door, which ignores extras.

import {
  nil,
  int,
  text,
  symbol,
  bytes,
  list,
  record,
  set,
  dict,
} from './value/build.js'
import { assertValue } from './value/value.js'

/** @import { Value } from './value/value.js' */

// `JSON.rawJSON` (ES2025 / Node ≥ 21) is not in this TypeScript's lib yet.
const RawJSON = /** @type {{ rawJSON(text: string): unknown }} */ (
  /** @type {unknown} */ (JSON)
)

/** A JSON value that is not a well-formed reading of a Bassline value. */
export class JSONError extends Error {}

/**
 * @param {string} msg
 * @returns {never}
 */
function refuse(msg) {
  throw new JSONError(msg)
}

/**
 * @param {unknown} cond
 * @param {string} msg
 * @returns {asserts cond}
 */
function need(cond, msg) {
  if (!cond) refuse(msg)
}

const KINDS = new Set([
  'nil',
  'number',
  'text',
  'symbol',
  'bytes',
  'list',
  'record',
  'dict',
  'set',
])

const CANONICAL_INT = /^(?:0|-?[1-9][0-9]*)$/

/**
 * The reviver `fromJSON` hands to `JSON.parse`: it replaces every JSON number
 * with an exact integer — a `number` where it fits, a `bigint` past 2^53 —
 * reading the digits from the parser's source so nothing is rounded, and
 * refuses a number that is not an integer spelling. Pass it to `JSON.parse`
 * directly to read a document the dialect functions don't take whole, such as
 * a top-level array of values.
 * @param {string} _key
 * @param {unknown} value
 * @param {{ source?: string }} [context]
 * @returns {unknown}
 */
export function numberReviver(_key, value, context) {
  if (typeof value !== 'number') return value
  const source = context && context.source
  if (source === undefined) {
    if (Number.isSafeInteger(value)) return value
    return refuse(
      'an integer past 2^53 needs a runtime with JSON source access (Node ≥ 22)'
    )
  }
  if (!CANONICAL_INT.test(source)) {
    return refuse('not an integer in the JSON dialect: ' + source)
  }
  return Number.isSafeInteger(value) ? value : BigInt(source)
}

/**
 * Parse JSON `text` and read it as a value.
 * @param {string} text
 * @returns {Value}
 */
export function fromJSON(text) {
  need(typeof text === 'string', 'fromJSON expects a string')
  let parsed
  try {
    parsed = JSON.parse(text, numberReviver)
  } catch (e) {
    if (e instanceof JSONError) throw e
    return refuse('not JSON: ' + (e instanceof Error ? e.message : String(e)))
  }
  return toValue(parsed)
}

/**
 * Read an already-parsed JSON structure as a value. A number must be an
 * integer within the safe range — for a wider integer, read the JSON text with
 * {@link fromJSON}, which recovers it losslessly.
 * @param {unknown} node
 * @returns {Value}
 */
export function toValue(node) {
  need(isObject(node), 'a value is a JSON object')
  const obj = /** @type {Record<string, unknown>} */ (node)

  for (const key of Object.keys(obj)) {
    need(
      key === 'kind' || key === 'mark' || key === 'value',
      'unknown key ' + JSON.stringify(key)
    )
  }

  need(typeof obj.kind === 'string', 'a value needs a string "kind"')
  const kind = obj.kind
  need(KINDS.has(kind), 'not a value kind: ' + kind)

  let mark = false
  if ('mark' in obj) {
    need(typeof obj.mark === 'boolean', '"mark" is a boolean')
    mark = obj.mark
  }

  if (kind === 'nil') {
    need(!('value' in obj), 'nil carries no "value"')
    return nil(mark)
  }

  need('value' in obj, kind + ' needs a "value"')
  const v = obj.value

  switch (kind) {
    case 'number':
      return int(integerValue(v), mark)
    case 'text':
      return text(stringValue(v, 'text'), mark)
    case 'symbol':
      return symbol(stringValue(v, 'symbol'), mark)
    case 'bytes':
      return bytes(hexValue(v), mark)
    case 'list':
      return list(valueArray(v), mark)
    case 'record': {
      const items = valueArray(v)
      need(items.length > 0, 'a record needs a head')
      return record(items, mark)
    }
    case 'dict': {
      const es = entryArray(v)
      const d = dict(es, mark)
      need(d.size === es.length, 'duplicate dict key')
      return d
    }
    case 'set': {
      const ms = valueArray(v)
      const s = set(ms, mark)
      need(s.size === ms.length, 'duplicate set member')
      return s
    }
    default:
      return refuse('not a value kind: ' + kind)
  }
}

/**
 * Write `value` as JSON-dialect text. An integer past 2^53 is emitted with
 * `JSON.rawJSON`, so it stays a JSON number.
 * @param {Value} value
 * @param {{ space?: number | string }} [opts]
 * @returns {string}
 */
export function toJSON(value, opts = {}) {
  assertValue(value)
  return JSON.stringify(nodeOf(value), null, opts.space)
}

/**
 * @param {Value} v
 * @returns {Record<string, unknown>}
 */
function nodeOf(v) {
  /** @type {Record<string, unknown>} */
  const node = { kind: v.kind }
  if (v.mark) node.mark = true
  switch (v.kind) {
    case 'nil':
      break
    case 'number':
      node.value = typeof v.value === 'bigint' ? wideNumber(v.value) : v.value
      break
    case 'text':
    case 'symbol':
      node.value = v.value
      break
    case 'bytes':
      node.value = '0x' + hex(v.value)
      break
    case 'list':
    case 'record':
      node.value = v.items.map(nodeOf)
      break
    case 'dict':
      node.value = [...v.entries()].map(([k, val]) => [nodeOf(k), nodeOf(val)])
      break
    case 'set':
      node.value = [...v.values()].map(nodeOf)
      break
  }
  return node
}

/**
 * A past-2^53 integer as a JSON number token that survives `JSON.stringify`.
 * @param {bigint} n
 * @returns {unknown}
 */
function wideNumber(n) {
  need(
    typeof RawJSON.rawJSON === 'function',
    'writing an integer past 2^53 needs a runtime with JSON.rawJSON (Node ≥ 22)'
  )
  return RawJSON.rawJSON(n.toString())
}

// ---- payload readers ----

/**
 * @param {unknown} x
 * @returns {boolean}
 */
function isObject(x) {
  return typeof x === 'object' && x !== null && !Array.isArray(x)
}

/**
 * @param {unknown} v
 * @returns {number | bigint}
 */
function integerValue(v) {
  if (typeof v === 'bigint') return v
  need(typeof v === 'number', 'a number\'s "value" is a JSON number')
  need(Number.isInteger(v), 'not an integer: ' + v)
  need(
    Number.isSafeInteger(v),
    'the integer ' + v + ' is past the safe range; read the text with fromJSON'
  )
  return v
}

/**
 * @param {unknown} v
 * @param {string} what
 * @returns {string}
 */
function stringValue(v, what) {
  need(typeof v === 'string', 'a ' + what + '\'s "value" is a string')
  need(v.isWellFormed(), 'malformed text in ' + what)
  return v
}

/**
 * @param {unknown} v
 * @returns {Uint8Array}
 */
function hexValue(v) {
  need(typeof v === 'string', 'bytes "value" is a "0x…" hex string')
  const m = /^0x([0-9a-fA-F]*)$/.exec(v)
  need(m !== null, 'not a "0x…" hex string: ' + v)
  const digits = m[1]
  need(digits.length % 2 === 0, 'bytes need an even number of hex digits')
  const out = new Uint8Array(digits.length / 2)
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(digits.slice(2 * i, 2 * i + 2), 16)
  }
  return out
}

/**
 * @param {unknown} v
 * @returns {Value[]}
 */
function valueArray(v) {
  need(Array.isArray(v), 'frame members are a JSON array')
  return v.map(toValue)
}

/**
 * @param {unknown} v
 * @returns {Array<[Value, Value]>}
 */
function entryArray(v) {
  need(Array.isArray(v), 'dict entries are an array of [key, value] pairs')
  return v.map(e => {
    need(Array.isArray(e) && e.length === 2, 'a dict entry is [key, value]')
    return /** @type {[Value, Value]} */ ([toValue(e[0]), toValue(e[1])])
  })
}

/**
 * @param {Uint8Array} u8
 * @returns {string}
 */
function hex(u8) {
  let s = ''
  for (const b of u8) s += b.toString(16).padStart(2, '0')
  return s
}
