// @ts-check
// Reader for the Bassline Textual Syntax

/** @import {Value} from "../data.js" */
import {
  BasslineBool,
  BasslineBytes,
  BasslineDict,
  BasslineFloat,
  BasslineInt,
  BasslineList,
  BasslineNil,
  BasslineRecord,
  BasslineSet,
  BasslineString,
  BasslineSymbol,
} from '../data.js'

const WS = ' \t\n\r,'
const DELIM = '[]{}<>():#\'"`'
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
  }
}

/**
 * Read source text into a document (zero or more values).
 * @param {string} source
 * @returns {Value[]}
 */
export function read(source) {
  if (typeof source !== 'string') throw new TypeError('read expects a string')

  const n = source.length
  let pos = 0
  /** @type {Value[]} */
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
   * @param {Value} value
   */
  function push(value) {
    values.push(value)
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
    return new BasslineBytes(out, actionable)
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
      return new BasslineFloat(val, actionable)
    } else {
      const val = BigInt(text)
      return new BasslineInt(val, actionable)
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
        return new BasslineNil(actionable)
      case 'true':
        return new BasslineBool(true, actionable)
      case 'false':
        return new BasslineBool(false, actionable)
      case 'NaN':
        return new BasslineFloat(NaN, actionable)
      case 'Infinity':
        return new BasslineFloat(Infinity, actionable)
      case '-Infinity':
        return new BasslineFloat(-Infinity, actionable)
      default:
        return new BasslineSymbol(text, actionable)
    }
  }

  /**
   *
   * @param {string} closer
   */
  function readUntil(closer) {
    /** @type {Value[]} */
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

  /** @param {boolean} actionable */
  function readList(actionable) {
    const items = readUntil(']')
    return new BasslineList(items, actionable)
  }

  /** @param {boolean} actionable */
  function readSet(actionable) {
    const items = readUntil('}')
    return new BasslineSet(items, actionable)
  }

  /** @param {boolean} actionable */
  function readRecord(actionable) {
    const items = readUntil('>')
    if (items.length === 0) fail(pos, `Record cannot be empty!`)
    return new BasslineRecord(items, actionable)
  }

  /** @param {boolean} actionable */
  function readDict(actionable) {
    /** @type {[Value, Value][]} */
    const entries = []
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
      entries.push([key, readValue()])
    }
    return new BasslineDict(entries, actionable)
  }

  function readValue() {
    const INVALID_CHARS = ':()]}>'
    let actionable = false
    while (isWs(source[pos])) pos++
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

    if (c === '[') {
      pos++
      return readList(actionable)
    }

    if (c === '{') {
      pos++
      return readDict(actionable)
    }

    if (c === '<') {
      pos++
      return readRecord(actionable)
    }

    if (c === '"') {
      pos++
      const val = readQuoted('"')
      return new BasslineString(val, actionable)
    }

    if (c === "'") {
      pos++
      const val = readQuoted("'")
      return new BasslineSymbol(val, actionable)
    }
    if (c === '#') {
      if (k === '{') {
        pos += 2
        return readSet(actionable)
      }
      if (k === '[') {
        pos += 2
        return readBytes(actionable)
      }
      // Note: I could see this not be an error but do a normal symbol parse
      fail(pos, "'#' must begin '#[' or '#{'")
    }
    const numberLike = isDigit(c) || (isSign(c) && isDigit(k))
    return numberLike
      ? readNumber(pos, actionable)
      : readSymbol(pos, actionable)
  }

  while (true) {
    while (isWs(source[pos])) pos++
    if (pos >= n) break
    push(readValue())
  }

  return values
}
