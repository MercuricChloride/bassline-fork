// Parser for the Bassline textual syntax: text -> a list of values.
//
// Recursive descent over the lexer's tokens. A Document is `Value*`. Semantic
// rules that the data model already enforces (dict keys and set members must be
// Data, no duplicates) are left to the data.js constructors — the parser just
// builds and lets them throw, so there is one source of truth for those rules.

import { lex, T } from './lexer.js'
import * as D from './data.js'

function positionOf(source, pos) {
  let line = 1
  let col = 1
  for (let k = 0; k < pos && k < source.length; k++) {
    if (source[k] === '\n') {
      line++
      col = 1
    } else {
      col++
    }
  }
  return `${line}:${col}`
}

/**
 * Parse source text into a list of values.
 * @param {string} source
 * @returns {import('./data.js').BasslineValue[]}
 */
export function parse(source) {
  const tokens = lex(source)
  let i = 0
  const peek = () => tokens[i]
  const next = () => tokens[i++]
  const fail = (tok, msg) => {
    const pos = tok ? tok.start : source.length
    throw new SyntaxError(`parse error at ${positionOf(source, pos)}: ${msg}`)
  }

  const expect = (type, what) => {
    const tok = peek()
    if (!tok || tok.type !== type) fail(tok, `expected ${what}`)
    return next()
  }

  // value* up to a closing token of `end` type (which is consumed).
  const parseSeq = (end, what) => {
    const out = []
    while (peek() && peek().type !== end) out.push(parseValue())
    expect(end, what)
    return out
  }

  const parseList = () => {
    next() // [
    return D.list(parseSeq(T.RBRACK, "']'"))
  }

  const parseSet = () => {
    next() // #{
    return D.set(parseSeq(T.RBRACE, "'}'"))
  }

  const parseRecord = () => {
    const open = next() // <
    if (!peek() || peek().type === T.RANGLE) fail(peek() ?? open, 'record needs a head')
    const head = parseValue()
    const fields = parseSeq(T.RANGLE, "'>'")
    return D.record(head, fields)
  }

  const parseDict = () => {
    next() // {
    const entries = []
    while (peek() && peek().type !== T.RBRACE) {
      const key = parseValue()
      expect(T.COLON, "':' in dictionary entry")
      entries.push([key, parseValue()])
    }
    expect(T.RBRACE, "'}'")
    return D.dict(entries)
  }

  const parseDatum = () => {
    const tok = peek()
    if (!tok) return fail(tok, 'unexpected end of input, expected a value')
    switch (tok.type) {
      case T.LBRACK:
        return parseList()
      case T.SETOPEN:
        return parseSet()
      case T.LANGLE:
        return parseRecord()
      case T.LBRACE:
        return parseDict()
      case T.NULL:
        return next(), D.nul()
      case T.BOOL:
        return next(), D.bool(tok.value)
      case T.INTEGER:
        return next(), D.int(tok.value)
      case T.DOUBLE:
        return next(), D.float(tok.value)
      case T.STRING:
        return next(), D.str(tok.value)
      case T.SYMBOL:
        return next(), D.sym(tok.value)
      case T.BYTES:
        return next(), D.bytes(tok.value)
      default:
        return fail(tok, `unexpected ${tok.type}`)
    }
  }

  const parseValue = () => {
    let marked = false
    if (peek() && peek().type === T.MARK) {
      next()
      marked = true
      if (peek() && peek().type === T.MARK) fail(peek(), 'a value carries at most one mark')
    }
    const datum = parseDatum()
    return marked ? D.mark(datum) : datum
  }

  const values = []
  while (i < tokens.length) values.push(parseValue())
  return values
}
