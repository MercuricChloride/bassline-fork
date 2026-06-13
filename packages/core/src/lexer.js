// Tokenizer for the Bassline textual syntax (data-model.org §"A textual syntax").
//
// Whitespace separates tokens and is otherwise insignificant. After skipping it,
// the first character selects the token. A *delimiter* (whitespace or one of
// [ ] { } < > ( ) : # ' | `) ends a bare symbol or number; every other character
// — including , ; + - * / . = ! ? — is an ordinary symbol character.

/** Token type tags. */
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
  MARK: 'MARK', //     `
  NULL: 'NULL',
  BOOL: 'BOOL', // value: boolean
  INTEGER: 'INTEGER', // value: bigint
  DOUBLE: 'DOUBLE', // value: number
  STRING: 'STRING', // value: string
  SYMBOL: 'SYMBOL', // value: string (spelling)
  BYTES: 'BYTES', // value: Uint8Array
}

const WS = new Set([' ', '\t', '\n', '\r'])
const DELIM = new Set(['[', ']', '{', '}', '<', '>', '(', ')', ':', '#', "'", '|', '`'])

const isWs = (c) => WS.has(c)
const isDigit = (c) => c >= '0' && c <= '9'
const isHex = (c) =>
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
/** A bare symbol or number ends here: at whitespace, a delimiter, or EOF. */
const isBoundary = (c) => c === undefined || isWs(c) || DELIM.has(c)

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
  return new SyntaxError(`lex error at ${line}:${col}: ${msg}`)
}

/**
 * Tokenize source text.
 * @param {string} source
 * @returns {Array<{type: string, value?: *, start: number, end: number}>}
 */
export function lex(source) {
  const n = source.length
  let pos = 0
  const tokens = []
  const fail = (p, msg) => {
    throw lexError(source, p, msg)
  }
  const push = (type, start, value) => tokens.push({ type, value, start, end: pos })

  // pos sits just after a backslash; consume and return the unescaped text.
  const readEscape = () => {
    const e = source[pos]
    pos++
    switch (e) {
      case "'":
        return "'"
      case '|':
        return '|'
      case '\\':
        return '\\'
      case 'n':
        return '\n'
      case 't':
        return '\t'
      case 'r':
        return '\r'
      case 'u': {
        if (source[pos] !== '{') fail(pos, 'expected { after \\u')
        pos++
        let hexs = ''
        while (source[pos] !== '}') {
          if (pos >= n) fail(pos, 'unterminated \\u{...}')
          if (!isHex(source[pos])) fail(pos, 'invalid hex digit in \\u{...}')
          hexs += source[pos]
          pos++
        }
        pos++ // consume }
        if (hexs.length === 0) fail(pos, 'empty \\u{}')
        const cp = parseInt(hexs, 16)
        if (cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) {
          fail(pos, 'code point out of range or a surrogate')
        }
        return String.fromCodePoint(cp)
      }
      default:
        return fail(pos - 1, `invalid escape \\${e ?? ''}`)
    }
  }

  // pos sits just after the opening quote; read until the matching closer.
  const readQuoted = (closer) => {
    let out = ''
    for (;;) {
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
  const readBytes = (start) => {
    const nibbles = []
    for (;;) {
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
    if (nibbles.length % 2 !== 0) fail(pos, 'bytestring has an odd number of hex digits')
    const out = new Uint8Array(nibbles.length / 2)
    for (let i = 0; i < out.length; i++) out[i] = nibbles[2 * i] * 16 + nibbles[2 * i + 1]
    push(T.BYTES, start, out)
  }

  // pos sits at the first character (a digit, or a sign on a digit).
  const readNumber = (start) => {
    let isDouble = false
    if (source[pos] === '+' || source[pos] === '-') pos++
    while (isDigit(source[pos])) pos++
    if (source[pos] === '.' && isDigit(source[pos + 1])) {
      isDouble = true
      pos++
      while (isDigit(source[pos])) pos++
    }
    if (source[pos] === 'e' || source[pos] === 'E') {
      let k = pos + 1
      if (source[k] === '+' || source[k] === '-') k++
      if (isDigit(source[k])) {
        isDouble = true
        pos = k + 1
        while (isDigit(source[pos])) pos++
      }
    }
    if (!isBoundary(source[pos])) fail(pos, 'number adjacent to a symbol character')
    const text = source.slice(start, pos)
    if (isDouble) push(T.DOUBLE, start, parseFloat(text))
    else push(T.INTEGER, start, BigInt(text[0] === '+' ? text.slice(1) : text))
  }

  // pos sits at the first character; read a maximal bare run, then reclassify.
  const readBare = (start) => {
    while (!isBoundary(source[pos])) pos++
    const text = source.slice(start, pos)
    switch (text) {
      case 'null':
        return push(T.NULL, start)
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
        push(T.MARK, start)
        break
      case "'":
        pos++
        push(T.STRING, start, readQuoted("'"))
        break
      case '|':
        pos++
        push(T.SYMBOL, start, readQuoted('|'))
        break
      case '#':
        if (source[pos + 1] === '{') {
          pos += 2
          push(T.SETOPEN, start)
        } else if (source[pos + 1] === '[') {
          pos += 2
          readBytes(start)
        } else {
          fail(start, "'#' must begin '#[' or '#{'")
        }
        break
      default:
        if (isDigit(c) || ((c === '+' || c === '-') && isDigit(source[pos + 1]))) {
          readNumber(start)
        } else {
          readBare(start)
        }
    }
  }
  return tokens
}
