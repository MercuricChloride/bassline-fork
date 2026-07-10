// @ts-check
// Reader for the Bassline Textual Syntax

/** @import {Value} from "../data.js" */
import {
  bytes,
  dict,
  eq,
  int,
  list,
  nil,
  record,
  set,
  string,
  symbol,
} from '../data.js'

const WS = ' \t\n\r,'
const DELIM = '[]{}():#\'"`;'

/** @type {(c: string) => boolean} */
const isWs = c => WS.includes(c)
/** @type {(c: string) => boolean} */
const isDigit = c => /[0-9]/.test(c)
/** @type {(c: string) => boolean} */
const isDelim = c => DELIM.includes(c)
/** @type {(c: string) => boolean} */
const isHex = c => /[0-9a-fA-F]/.test(c)
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
 * @param {{maxDepth?: number}} [opts]
 * @returns {Value[]}
 */
export function read(source, opts) {
  return readSpans(source, opts).map(s => s.value)
}

/**
 * Like {@link read}, but each value is wrapped with its source span. `read` is
 * the projection `readSpans(source).map(s => s.value)`, so the values produced
 * are identical; only the span metadata is extra.
 * @param {string} source
 * @param {{maxDepth?: number}} [opts]
 * @returns {Spanned[]}
 */
export function readSpans(source, { maxDepth = 1024 } = {}) {
  if (typeof source !== 'string') throw new TypeError('read expects a string')

  const n = source.length
  let pos = 0
  let depth = 0
  /** @type {Spanned[]} */
  const values = []

  /**
   * @param {number} p
   * @param {string} msg
   * @throws {ReaderError}
   * @returns {never}
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

  /**
   * Enforce the depth limit around reading one frame's body.
   * @template T
   * @param {number} at the frame's opening position
   * @param {() => T} readBody
   * @returns {T}
   */
  function framed(at, readBody) {
    if (++depth > maxDepth) fail(at, 'maximum depth exceeded')
    const out = readBody()
    depth--
    return out
  }

  /**
   * Fail at the first span whose value repeats an earlier one. Called only
   * after a constructor's canonicalization dropped a duplicate.
   * @param {Spanned[]} spans
   * @param {string} what
   * @returns {never}
   */
  function failDuplicate(spans, what) {
    for (let i = 1; i < spans.length; i++) {
      for (let j = 0; j < i; j++) {
        if (eq(spans[j].value, spans[i].value))
          fail(spans[i].start, `duplicate ${what}`)
      }
    }
    return fail(pos, `duplicate ${what}`)
  }

  // Skip whitespace and comments. A `;` begins a comment that runs to the
  // end of the line; comments are trivia and never reach the value space.
  function skipTrivia() {
    while (pos < n) {
      if (isWs(source[pos])) {
        pos++
      } else if (source[pos] === ';') {
        while (pos < n && source[pos] !== '\n') pos++
      } else {
        break
      }
    }
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
    return bytes(out, actionable)
  }

  // pos sits at the first character (a digit, or a sign on a digit).
  /**
   * @param {number} start
   * @param {boolean} actionable
   */
  function readNumber(start, actionable) {
    if (source[pos] === '-') pos++
    while (isDigit(source[pos])) pos++
    if (source[pos] === '.' && isDigit(source[pos + 1]))
      fail(
        pos,
        'no decimal number literals: non-integer numbers are vocabulary'
      )
    if (!isBoundary(source[pos]))
      fail(pos, 'number adjacent to a symbol character')
    const text = source.slice(start, pos)
    return int(BigInt(text), actionable)
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
    if (text === 'nil') return nil(actionable)
    return symbol(text, actionable)
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
      skipTrivia()
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
      value: list(
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
    const value = set(
      items.map(s => s.value),
      actionable
    )
    // the constructor canonicalizes; a dropped member means the source
    // spelled the same value twice
    if (value.value.length !== items.length) failDuplicate(items, 'set member')
    return { value, children: items }
  }

  /**
   * @param {boolean} actionable
   * @returns {{ value: Value, children: Spanned[] }}
   */
  function readRecord(actionable) {
    const items = readUntil(')')
    if (items.length === 0) fail(pos, `Record cannot be empty!`)
    return {
      value: record(
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
      skipTrivia()
      if (pos >= n) fail(pos, "unterminated, expected '}'")
      if (source[pos] === '}') {
        pos++
        break
      }
      const key = readValue()
      skipTrivia()
      if (source[pos] === ':') pos++
      else fail(pos, "dictionary expected a separator ':'")
      const val = readValue()
      entries.push([key.value, val.value])
      children.push(key, val)
    }
    const value = dict(entries, actionable)
    if (value.value.length !== entries.length)
      failDuplicate(
        children.filter((_, i) => i % 2 === 0),
        'dictionary key'
      )
    return { value, children }
  }

  /** @returns {Spanned} */
  function readValue() {
    const INVALID_CHARS = ':)]}'
    let actionable = false
    skipTrivia()
    const start = pos
    if (source[pos] === '`') {
      pos++
      actionable = true
      // the mark is one bit with one spelling, bound to the value it prefixes
      if (source[pos] === '`') fail(pos, 'repeated mark')
      if (isEOF(source[pos]) || isWs(source[pos]) || source[pos] === ';')
        fail(pos, 'a mark must immediately prefix its value')
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
      ;({ value, children } = framed(start, () => readList(actionable)))
    } else if (c === '{') {
      pos++
      ;({ value, children } = framed(start, () => readDict(actionable)))
    } else if (c === '(') {
      pos++
      ;({ value, children } = framed(start, () => readRecord(actionable)))
    } else if (c === '"') {
      pos++
      value = string(readQuoted('"'), actionable)
    } else if (c === "'") {
      pos++
      value = symbol(readQuoted("'"), actionable)
    } else if (c === '#') {
      if (k === '{') {
        pos += 2
        ;({ value, children } = framed(start, () => readSet(actionable)))
      } else if (k === '[') {
        pos += 2
        value = readBytes(actionable)
      } else {
        // Note: I could see this not be an error but do a normal symbol parse
        fail(pos, "'#' must begin '#[' or '#{'")
      }
    } else {
      const numberLike = isDigit(c) || (c === '-' && isDigit(k))
      value = numberLike
        ? readNumber(pos, actionable)
        : readSymbol(pos, actionable)
    }

    return { value, start, end: pos, children }
  }

  while (true) {
    skipTrivia()
    if (pos >= n) break
    push(readValue())
  }

  return values
}
