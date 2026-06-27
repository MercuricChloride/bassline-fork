// @ts-check
// Reader for the Bassline Textual Syntax

/** @import {Value} from "../data.js" */
import { fresh } from '../data.js'

const WS = ' \t\n\r,'
const DELIM = '[]{}():#\'"`'
const SIGNS = '+-'

/** @type {(c: string) => boolean} */
const isWs = c => WS.includes(c)
/** @type {(c: string) => boolean} */
const isDigit = c => /[0-9]/.test(c)
/** @type {(c: string) => boolean} */
const isDelim = c => DELIM.includes(c)
/** @type {(c: string) => boolean} */
const isHex = c => /[0-9a-fA-F]/.test(c)
/** @type {(c: string) => boolean} */
const isSign = c => SIGNS.includes(c)
/** @type {(c: unknown) => c is undefined} */
const isEOF = c => c === undefined

/** @type {(c: string) => boolean} */
const isBoundary = c => isEOF(c) || isWs(c) || isDelim(c)

export class ReaderError extends Error {
  /**
   * @param {string} source
   * @param {number} pos
   * @param {string} msg
   */
  constructor(source, pos, msg) {
    let line = 1
    let col = 1
    for (let i = 0; i < pos && i < source.length; i++) {
      if (source[i] === '\n') {
        line++
        col = 1
      } else {
        col++
      }
    }
    super(`reader error at ${line}:${col}: ${msg}`)
    /** Byte offset into the source where the error was detected. */
    this.pos = pos
    this.line = line
    this.col = col
  }
}

/**
 * A parsed value together with its source span and child spans. `start` sits
 * before any actionable `` ` ``; `end` is just past the form. `children` are the
 * sub-spans in document order (record head + fields, dict keys + values, list
 * and set members); atoms have none.
 * @typedef {object} Spanned
 * @property {Value} value
 * @property {number} start
 * @property {number} end
 * @property {Spanned[]} children
 */

/**
 * Read source text into a document (zero or more values).
 * @param {string} source
 * @returns {Value[]}
 */
export function read(source) {
  return readSpans(source).map(s => s.value)
}

/**
 * Like {@link read}, but each value is wrapped with its source span. `read` is
 * the projection `readSpans(source).map(s => s.value)`, so the values produced
 * are identical; only the span metadata is extra.
 * @param {string} source
 * @returns {Spanned[]}
 */
export function readSpans(source) {
  if (typeof source !== 'string') throw new TypeError('read expects a string')

  const n = source.length
  let pos = 0
  /** @type {Spanned[]} */
  const values = []

  /**
   * @param {number} p
   * @param {string} msg
   * @throws {ReaderError}
   */
  function fail(p, msg) {
    throw new ReaderError(source, p, msg)
  }

  /**
   * @param {Spanned} span
   */
  function push(span) {
    values.push(span)
  }

  function readEscape() {
    const e = source[pos]
    pos++
    switch (e) {
      case '"':
        return '"'
      case "'":
        return "'"
      case '\\':
        return '\\'
      case 'n':
        return '\n'
      case 't':
        return '\t'
      case 'r':
        return '\r'
      default:
        return fail(pos - 1, `invalid escape \\${e ?? ''}`)
    }
  }

  /**
   * pos sits just after the opening quote; read until the matching closer.
   * @param {string} closer
   */
  function readQuoted(closer) {
    let out = ''
    while (true) {
      if (pos >= n) fail(pos, 'unterminated literal')
      const c = source[pos]
      if (c === closer) {
        pos++
        return out
      }
      if (c === '\\') {
        pos++
        out += readEscape()
      } else {
        out += c
        pos++
      }
    }
  }

  // pos sits just after '#['; read hex pairs (inner whitespace ignored) to ']'.
  /**
   * @param {boolean} actionable
   */
  function readBytes(actionable) {
    const nibbles = []
    while (true) {
      if (pos >= n) fail(pos, 'unterminated bytestring')
      const c = source[pos]
      if (c === ']') {
        pos++
        break
      } else if (isWs(c)) {
        pos++
        continue
      } else if (isHex(c)) {
        nibbles.push(parseInt(c, 16))
        pos++
        continue
      } else {
        fail(pos, `Invalid hex digit in bytestring: ${c}`)
      }
    }
    if (nibbles.length % 2 !== 0)
      fail(pos, 'bytestring has an odd number of hex digits')
    const out = new Uint8Array(nibbles.length / 2)
    for (let i = 0; i < out.length; i++) {
      const offset = 2 * i
      const a = nibbles[offset]
      const b = nibbles[offset + 1]
      out[i] = a * 16 + b
    }
    return fresh.bytes(out, actionable)
  }

  // pos sits at the first character (a digit, or a sign on a digit).
  /**
   * @param {number} start
   * @param {boolean} actionable
   */
  function readNumber(start, actionable) {
    let isDouble = false
    if (isSign(source[pos])) pos++
    while (isDigit(source[pos])) pos++
    if (source[pos] === '.' && isDigit(source[pos + 1])) {
      isDouble = true
      pos++
      while (isDigit(source[pos])) pos++
    }
    if (source[pos] === 'e' || source[pos] === 'E') {
      let k = pos + 1
      if (isSign(source[k])) k++
      if (isDigit(source[k])) {
        isDouble = true
        pos = k + 1
        while (isDigit(source[pos])) pos++
      }
    }
    if (!isBoundary(source[pos]))
      fail(pos, 'number adjacent to a symbol character')
    const text = source.slice(start, pos)
    if (isDouble) {
      const val = parseFloat(text)
      return fresh.float(val, actionable)
    } else {
      const val = BigInt(text)
      return fresh.int(val, actionable)
    }
  }

  // pos sits at the first character; read a maximal bare run, then reclassify.
  /**
   *
   * @param {number} start
   * @param {boolean} actionable
   */
  function readSymbol(start, actionable) {
    while (!isBoundary(source[pos])) pos++
    const text = source.slice(start, pos)
    switch (text) {
      case 'nil':
        return fresh.nil(actionable)
      case 'true':
        return fresh.bool(true, actionable)
      case 'false':
        return fresh.bool(false, actionable)
      case 'NaN':
        return fresh.float(NaN, actionable)
      case 'Infinity':
        return fresh.float(Infinity, actionable)
      case '-Infinity':
        return fresh.float(-Infinity, actionable)
      default:
        return fresh.symbol(text, actionable)
    }
  }

  /**
   * Read child values until `closer`, returning their spans in document order.
   * @param {string} closer
   * @returns {Spanned[]}
   */
  function readUntil(closer) {
    /** @type {Spanned[]} */
    const items = []
    while (true) {
      while (isWs(source[pos])) pos++
      if (pos >= n) fail(pos, `unterminated, expected '${closer}'`)
      if (source[pos] === closer) {
        pos++
        return items
      }
      items.push(readValue())
    }
  }

  /**
   * @param {boolean} actionable
   * @returns {{ value: Value, children: Spanned[] }}
   */
  function readList(actionable) {
    const items = readUntil(']')
    return {
      value: fresh.list(
        items.map(s => s.value),
        actionable
      ),
      children: items,
    }
  }

  /**
   * @param {boolean} actionable
   * @returns {{ value: Value, children: Spanned[] }}
   */
  function readSet(actionable) {
    const items = readUntil('}')
    return {
      value: fresh.set(
        items.map(s => s.value),
        actionable
      ),
      children: items,
    }
  }

  /**
   * @param {boolean} actionable
   * @returns {{ value: Value, children: Spanned[] }}
   */
  function readRecord(actionable) {
    const items = readUntil(')')
    if (items.length === 0) fail(pos, `Record cannot be empty!`)
    return {
      value: fresh.record(
        items.map(s => s.value),
        actionable
      ),
      children: items,
    }
  }

  /**
   * @param {boolean} actionable
   * @returns {{ value: Value, children: Spanned[] }}
   */
  function readDict(actionable) {
    /** @type {[Value, Value][]} */
    const entries = []
    /** @type {Spanned[]} */
    const children = []
    while (true) {
      while (isWs(source[pos])) pos++
      if (pos >= n) fail(pos, "unterminated, expected '}'")
      if (source[pos] === '}') {
        pos++
        break
      }
      const key = readValue()
      while (isWs(source[pos])) pos++
      if (source[pos] === ':') pos++
      else fail(pos, "dictionary expected a separator ':'")
      const val = readValue()
      entries.push([key.value, val.value])
      children.push(key, val)
    }
    return { value: fresh.dict(entries, actionable), children }
  }

  /** @returns {Spanned} */
  function readValue() {
    const INVALID_CHARS = ':)]}'
    let actionable = false
    while (isWs(source[pos])) pos++
    const start = pos
    while (source[pos] === '`') {
      pos++
      actionable = true
    }
    const c = source[pos]
    const k = source[pos + 1]

    if (isEOF(c)) fail(pos, 'expected a value')

    if (INVALID_CHARS.includes(c)) {
      fail(pos, `unexpected closing character: ${c}`)
    }

    /** @type {Value} */
    let value
    /** @type {Spanned[]} */
    let children = []

    if (c === '[') {
      pos++
      ;({ value, children } = readList(actionable))
    } else if (c === '{') {
      pos++
      ;({ value, children } = readDict(actionable))
    } else if (c === '(') {
      pos++
      ;({ value, children } = readRecord(actionable))
    } else if (c === '"') {
      pos++
      value = fresh.string(readQuoted('"'), actionable)
    } else if (c === "'") {
      pos++
      value = fresh.symbol(readQuoted("'"), actionable)
    } else if (c === '#') {
      if (k === '{') {
        pos += 2
        ;({ value, children } = readSet(actionable))
      } else if (k === '[') {
        pos += 2
        value = readBytes(actionable)
      } else {
        // Note: I could see this not be an error but do a normal symbol parse
        fail(pos, "'#' must begin '#[' or '#{'")
      }
    } else {
      const numberLike = isDigit(c) || (isSign(c) && isDigit(k))
      value = numberLike
        ? readNumber(pos, actionable)
        : readSymbol(pos, actionable)
    }

    return { value, start, end: pos, children }
  }

  while (true) {
    while (isWs(source[pos])) pos++
    if (pos >= n) break
    push(readValue())
  }

  return values
}
