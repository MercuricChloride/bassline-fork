// Tokenizer for the Bassline textual syntax
// Whitespace separates tokens and is otherwise insignificant. After skipping it,
// the first character selects the token. A *delimiter* (whitespace or one of
// [ ] { } < > ( ) : # ' " `) ends a bare symbol or number; every other character
// — including ; + - * / . = ! ? | — is an ordinary symbol character.

export const T = {
  LBRACK: 'LBRACK', // [
  RBRACK: 'RBRACK', // ]
  LBRACE: 'LBRACE', // {
  RBRACE: 'RBRACE', // }
  LANGLE: 'LANGLE', // <
  RANGLE: 'RANGLE', // >
  LPAREN: 'LPAREN', // ( (reserved)
  RPAREN: 'RPAREN', // ) (reserved)
  COLON: 'COLON', //   :
  SETOPEN: 'SETOPEN', // #{
  ACTION: 'ACTION', //     `
  NIL: 'NIL',
  BOOL: 'BOOL', // value: boolean
  INTEGER: 'INTEGER', // value: bigint
  DOUBLE: 'DOUBLE', // value: number
  STRING: 'STRING', // value: string
  SYMBOL: 'SYMBOL', // value: string (spelling)
  BYTES: 'BYTES', // value: Uint8Array
}

const WS = ' \t\n\r,'
const DELIM = '[]{}<>():#\'"`'
const SIGNS = '+-'

const isWs = c => WS.includes(c)
const isDigit = c => /[0-9]/.test(c)
const isDelim = c => DELIM.includes(c)
const isHex = c => /[0-9a-fA-F]/.test(c)
const isSign = c => SIGNS.includes(c)
const isEOF = c => c === undefined

const isBoundary = c => isEOF(c) || isWs(c) || isDelim(c)

function lexError(source, pos, msg) {
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
  return new Error(`lex error at ${line}:${col}: ${msg}`)
}

/**
 * Tokenize source text.
 * @param {string} source
 * @returns {Array<{type: string, value?: *, start: number, end: number}>}
 */
export function lex(source) {
  if (typeof source !== 'string') throw new TypeError('lex expects a string')

  const n = source.length
  let pos = 0
  const tokens = []
  const fail = (p, msg) => {
    throw lexError(source, p, msg)
  }
  const push = (type, start, value) =>
    tokens.push({ type, value, start, end: pos })

  const readEscape = () => {
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

  // pos sits just after the opening quote; read until the matching closer.
  const readQuoted = closer => {
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
  const readBytes = start => {
    const nibbles = []
    while (true) {
      if (pos >= n) fail(pos, 'unterminated bytestring')
      const c = source[pos]
      if (c === ']') {
        pos++
        break
      }
      if (isWs(c)) {
        pos++
        continue
      }
      if (!isHex(c)) fail(pos, 'invalid hex digit in bytestring')
      nibbles.push(parseInt(c, 16))
      pos++
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
    push(T.BYTES, start, out)
  }

  // pos sits at the first character (a digit, or a sign on a digit).
  const readNumber = start => {
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
    if (isDouble) push(T.DOUBLE, start, parseFloat(text))
    else push(T.INTEGER, start, BigInt(text[0] === '+' ? text.slice(1) : text))
  }

  // pos sits at the first character; read a maximal bare run, then reclassify.
  const readBare = start => {
    while (!isBoundary(source[pos])) pos++
    const text = source.slice(start, pos)
    switch (text) {
      case 'nil':
        return push(T.NIL, start)
      case 'true':
        return push(T.BOOL, start, true)
      case 'false':
        return push(T.BOOL, start, false)
      case 'NaN':
        return push(T.DOUBLE, start, NaN)
      case 'Infinity':
        return push(T.DOUBLE, start, Infinity)
      case '-Infinity':
        return push(T.DOUBLE, start, -Infinity)
      default:
        return push(T.SYMBOL, start, text)
    }
  }

  while (pos < n) {
    const c = source[pos]
    if (isWs(c)) {
      pos++
      continue
    }
    const start = pos
    switch (c) {
      case '[':
        pos++
        push(T.LBRACK, start)
        break
      case ']':
        pos++
        push(T.RBRACK, start)
        break
      case '{':
        pos++
        push(T.LBRACE, start)
        break
      case '}':
        pos++
        push(T.RBRACE, start)
        break
      case '<':
        pos++
        push(T.LANGLE, start)
        break
      case '>':
        pos++
        push(T.RANGLE, start)
        break
      case '(':
        pos++
        push(T.LPAREN, start)
        break
      case ')':
        pos++
        push(T.RPAREN, start)
        break
      case ':':
        pos++
        push(T.COLON, start)
        break
      case '`':
        pos++
        push(T.ACTION, start)
        break
      case '"':
        pos++
        push(T.STRING, start, readQuoted('"'))
        break
      case "'":
        pos++
        push(T.SYMBOL, start, readQuoted("'"))
        break
      case '#': {
        const k = pos + 1
        if (source[k] === '{') {
          pos += 2
          push(T.SETOPEN, start)
        } else if (source[k] === '[') {
          pos += 2
          readBytes(start)
        } else {
          // TODO: Unsure whether to turn this into a readBare invocation
          fail(start, "'#' must begin '#[' or '#{'")
        }
        break
      }
      default:
        if (isDigit(c) || (isSign(c) && isDigit(source[pos + 1]))) {
          readNumber(start)
        } else {
          readBare(start)
        }
    }
  }
  return tokens
}
