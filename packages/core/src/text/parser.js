import { lex, T } from './lexer.js'
import * as D from '../data.js'

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
 * Parse source text into a Document: an array of values.
 * @param {string} source
 * @returns {import('../data.js').BasslineValue[]}
 */
export function parse(source) {
  if (typeof source !== 'string') throw new TypeError('parse expects a string')
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

  // value up to a closing token of `end` type (which is consumed).
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
    const open = next() // #{
    const members = parseSeq(T.RBRACE, "'}'")
    const seen = new Set()
    for (const m of members) {
      const ck = D.ceKey(m)
      if (seen.has(ck)) fail(open, 'duplicate set member')
      seen.add(ck)
    }
    return D.set(members)
  }

  const parseRecord = () => {
    const open = next() // <
    if (!peek() || peek().type === T.RANGLE)
      fail(peek() ?? open, 'record needs a head')
    const head = parseValue()
    const fields = parseSeq(T.RANGLE, "'>'")
    return D.record(head, fields)
  }

  const parseDict = () => {
    const open = next() // {
    const entries = []
    const seen = new Set()
    while (peek() && peek().type !== T.RBRACE) {
      const key = parseValue()
      expect(T.COLON, "':' in dictionary entry")
      const val = parseValue()
      const ck = D.ceKey(key)
      if (seen.has(ck)) fail(open, 'duplicate dict key')
      seen.add(ck)
      entries.push([key, val])
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
      case T.NIL:
        return (next(), D.nil())
      case T.BOOL:
        return (next(), D.bool(tok.value))
      case T.INTEGER:
        return (next(), D.int(tok.value))
      case T.DOUBLE:
        return (next(), D.float(tok.value))
      case T.STRING:
        return (next(), D.str(tok.value))
      case T.SYMBOL:
        return (next(), D.sym(tok.value))
      case T.BYTES:
        return (next(), D.bytes(tok.value))
      default:
        return fail(tok, `unexpected ${tok.type}`)
    }
  }

  const parseValue = () => {
    let marked = false
    if (peek() && peek().type === T.ACTION) {
      next()
      marked = true
      if (peek() && peek().type === T.ACTION)
        fail(peek(), 'a value carries at most one mark')
    }
    const datum = parseDatum()
    return marked ? datum.toActionable() : datum
  }

  const values = []
  while (i < tokens.length) values.push(parseValue())
  return values
}
