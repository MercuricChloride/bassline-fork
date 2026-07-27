// @ts-check
// Reader for the Bassline Textual Syntax

/** @import {Value} from "../data.js" */
import {
  CANONICAL_INT,
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
  withMark,
} from '../data.js'

const WS = ' \t\n\r'
const DELIM = '[]{}():\'";!'
const OPENERS = '([{'

/** @type {(c: string) => boolean} */
const isWs = c => WS.includes(c)
/** @type {(c: string | undefined) => boolean} */
const isDigit = c => c !== undefined && /[0-9]/.test(c)
/** @type {(c: string) => boolean} */
const isDelim = c => DELIM.includes(c)
/** @type {(c: string | undefined) => boolean} */
const isHex = c => c !== undefined && /[0-9a-fA-F]/.test(c)
/** @type {(c: unknown) => c is undefined} */
const isEOF = c => c === undefined
/** @type {(c: string | undefined) => boolean} */
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
    /** UTF-16 code-unit offset into the source where the error was detected. */
    this.pos = pos
    this.line = line
    this.col = col
  }
}

/**
 * A parsed value together with its source span and child spans, in UTF-16
 * code-unit offsets. The mark is part of the span: `start` sits before a
 * frame's leading `!`, and `end` sits just past an atom's trailing `!`.
 * `children` are the sub-spans in document order (record head + fields, dict
 * keys + values, list and set members); atoms have none.
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
 *
 * The reader recurses per frame, so a `maxDepth` far past the default trades
 * the positioned depth error for the engine's own stack-overflow ceiling
 * (around 1700 frames).
 * @param {string} source
 * @param {{maxDepth?: number}} [opts]
 * @returns {Spanned[]}
 */
export function readSpans(source, opts) {
  if (typeof source !== 'string') throw new TypeError('read expects a string')
  const { maxDepth = 1024 } = opts ?? {}

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

  /**
   * pos sits on the backslash's escape character; the only escapes are the
   * closing quote, and \\ \n \t \r.
   * @param {string} closer
   */
  function readEscape(closer) {
    const e = source[pos]
    pos++
    switch (e) {
      case closer:
        return closer
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
   * Any character but the closer and backslash is held literally (a raw
   * newline is legal inside quotes).
   * @param {string} closer
   * @param {string} what
   */
  function readQuoted(closer, what) {
    let out = ''
    while (true) {
      if (pos >= n) fail(pos, `unterminated ${what}`)
      const c = source[pos]
      if (c === closer) {
        pos++
        return out
      }
      if (c === '\\') {
        pos++
        if (pos >= n) fail(pos, `unterminated ${what}`)
        out += readEscape(closer)
      } else {
        out += c
        pos++
      }
    }
  }

  /**
   * A maximal run of non-delimiter characters starting at `start` (where pos
   * already sits). The token is classified afterwards: bytes, number, nil,
   * or symbol.
   * @param {number} start
   */
  function readBareToken(start) {
    while (pos < n && !isBoundary(source[pos])) pos++
    return source.slice(start, pos)
  }

  /**
   * A bare token opening with `0x` is a bytestring: an even count of hex
   * digits, either case, with `_` allowed between two digits as a visual
   * separator. `0x` alone is the empty bytestring.
   * @param {string} tok
   * @param {number} start
   */
  function bytesFromToken(tok, start) {
    let digits = ''
    for (let i = 2; i < tok.length; i++) {
      const c = tok[i]
      if (c === '_') {
        if (!isHex(tok[i - 1]) || !isHex(tok[i + 1]))
          fail(start + i, "'_' sits between digits")
      } else if (isHex(c)) {
        digits += c
      } else {
        fail(start + i, `not a hex digit in bytes: ${c}`)
      }
    }
    if (digits.length % 2 !== 0)
      fail(start, 'bytes need an even count of hex digits')
    const out = new Uint8Array(digits.length / 2)
    for (let i = 0; i < out.length; i++) {
      out[i] = parseInt(digits.slice(2 * i, 2 * i + 2), 16)
    }
    return bytes(out)
  }

  /**
   * A bare token opening with a digit, or a `-` on a digit, is a number.
   * `_` is allowed between two digits; the digits left after dropping the
   * separators must be the canonical decimal spelling.
   * @param {string} tok
   * @param {number} start
   */
  function intFromToken(tok, start) {
    let digits = ''
    for (let i = 0; i < tok.length; i++) {
      const c = tok[i]
      if (c === '_') {
        if (!isDigit(tok[i - 1]) || !isDigit(tok[i + 1]))
          fail(start + i, "'_' sits between digits")
      } else {
        digits += c
      }
    }
    if (!CANONICAL_INT.test(digits))
      fail(start, `not a canonical number: ${tok}`)
    return int(BigInt(digits))
  }

  /**
   * Read child values until `closer`, returning their spans in document order.
   * @param {string} opener
   * @param {string} closer
   * @returns {Spanned[]}
   */
  function readUntil(opener, closer) {
    /** @type {Spanned[]} */
    const items = []
    while (true) {
      skipTrivia()
      if (pos >= n) fail(pos, `unclosed ${opener}`)
      if (source[pos] === closer) {
        pos++
        return items
      }
      items.push(readValue())
    }
  }

  /** @returns {{ value: Value, children: Spanned[] }} */
  function readList() {
    const items = readUntil('[', ']')
    return { value: list(items.map(s => s.value)), children: items }
  }

  /** @returns {{ value: Value, children: Spanned[] }} */
  function readRecord() {
    const items = readUntil('(', ')')
    if (items.length === 0) fail(pos - 1, 'record with no head')
    return { value: record(items.map(s => s.value)), children: items }
  }

  /**
   * One brace family: the first element decides. A `:` after it makes a
   * dictionary; no `:` makes a set. `{}` is the empty set, `{:}` the empty
   * dictionary — no colon, no dict, even at zero elements.
   * @returns {{ value: Value, children: Spanned[] }}
   */
  function readBraces() {
    skipTrivia()
    if (pos >= n) fail(pos, 'unclosed {')
    if (source[pos] === '}') {
      pos++
      return { value: set([]), children: [] }
    }
    if (source[pos] === ':') {
      pos++
      skipTrivia()
      if (pos >= n) fail(pos, 'unclosed {')
      if (source[pos] !== '}')
        fail(pos, "'{:' is the empty dictionary; expected '}'")
      pos++
      return { value: dict([]), children: [] }
    }
    const first = readValue()
    skipTrivia()
    if (pos >= n) fail(pos, 'unclosed {')
    if (source[pos] === ':') {
      pos++
      return readDictAfter(first)
    }
    return readSetAfter(first)
  }

  /**
   * pos sits just after the first key's `:`; read the dictionary's entries.
   * @param {Spanned} firstKey
   * @returns {{ value: Value, children: Spanned[] }}
   */
  function readDictAfter(firstKey) {
    /** @type {[Value, Value][]} */
    const entries = []
    /** @type {Spanned[]} */
    const children = []
    let key = firstKey
    while (true) {
      const val = readValue()
      entries.push([key.value, val.value])
      children.push(key, val)
      skipTrivia()
      if (pos >= n) fail(pos, 'unclosed {')
      if (source[pos] === '}') {
        pos++
        break
      }
      key = readValue()
      skipTrivia()
      if (pos >= n || source[pos] !== ':')
        fail(pos, "dict entry needs ':' after its key")
      pos++
    }
    const value = dict(entries)
    // the constructor canonicalizes; a dropped entry means the source
    // spelled the same key twice
    if (value.value.length !== entries.length)
      failDuplicate(
        children.filter((_, i) => i % 2 === 0),
        'dict key'
      )
    return { value, children }
  }

  /**
   * pos sits after the first member; read the set's remaining members.
   * @param {Spanned} first
   * @returns {{ value: Value, children: Spanned[] }}
   */
  function readSetAfter(first) {
    const items = [first]
    while (true) {
      skipTrivia()
      if (pos >= n) fail(pos, 'unclosed {')
      if (source[pos] === '}') {
        pos++
        break
      }
      if (source[pos] === ':')
        fail(pos, "':' in a set; a dictionary is {key: value}")
      items.push(readValue())
    }
    const value = set(items.map(s => s.value))
    // the constructor canonicalizes; a dropped member means the source
    // spelled the same value twice
    if (value.value.length !== items.length) failDuplicate(items, 'set member')
    return { value, children: items }
  }

  /**
   * Construct a string/symbol, converting a well-formedness rejection into a
   * positioned reader error.
   * @param {(s: string) => Value} ctor
   * @param {string} raw
   * @param {number} at
   * @param {string} what
   */
  function wellFormed(ctor, raw, at, what) {
    try {
      return ctor(raw)
    } catch {
      return fail(at, `malformed text in ${what}`)
    }
  }

  /** @returns {Spanned} */
  function readValue() {
    skipTrivia()
    const start = pos

    let prefixMarked = false
    if (source[pos] === '!') {
      // a mark in front belongs to a frame; it must touch the bracket
      pos++
      if (isEOF(source[pos])) fail(pos, 'mark with no value')
      if (source[pos] === '!') fail(pos, 'repeated mark')
      if (isWs(source[pos]) || source[pos] === ';')
        fail(pos, 'mark separated from its value')
      if (!OPENERS.includes(source[pos]))
        fail(
          pos,
          'only a frame is marked in front; an atom is marked behind: x!'
        )
      prefixMarked = true
    }

    const c = source[pos]
    if (isEOF(c)) fail(pos, 'expected a value')
    if (':)]}'.includes(c)) fail(pos, `unexpected ${c}`)

    const frame = OPENERS.includes(c)

    /** @type {Value} */
    let value
    /** @type {Spanned[]} */
    let children = []

    if (c === '[') {
      pos++
      ;({ value, children } = framed(start, readList))
    } else if (c === '(') {
      pos++
      ;({ value, children } = framed(start, readRecord))
    } else if (c === '{') {
      pos++
      ;({ value, children } = framed(start, readBraces))
    } else if (c === '"') {
      pos++
      value = wellFormed(string, readQuoted('"', 'string'), start, 'string')
    } else if (c === "'") {
      pos++
      value = wellFormed(symbol, readQuoted("'", 'symbol'), start, 'symbol')
    } else {
      const tok = readBareToken(start)
      if (tok.length >= 2 && tok[0] === '0' && tok[1] === 'x') {
        value = bytesFromToken(tok, start)
      } else if (isDigit(tok[0]) || (tok[0] === '-' && isDigit(tok[1]))) {
        value = intFromToken(tok, start)
      } else if (tok === 'nil') {
        value = nil()
      } else {
        value = wellFormed(symbol, tok, start, 'symbol')
      }
    }

    if (source[pos] === '!') {
      // a mark behind belongs to an atom; it must touch the atom and end at
      // a delimiter
      if (frame) fail(pos, 'a frame is marked in front: !(…)')
      pos++
      if (!isBoundary(source[pos]))
        fail(pos, 'a marked atom ends at a delimiter')
      value = withMark(value, true)
    } else if (prefixMarked) {
      value = withMark(value, true)
    }

    return { value, start, end: pos, children }
  }

  while (true) {
    skipTrivia()
    if (pos >= n) break
    values.push(readValue())
  }

  return values
}
