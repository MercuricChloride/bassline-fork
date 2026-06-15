// Pretty-printer: a Bassline value -> indented textual syntax.
//
// The output is a non-canonical human surface; its one guarantee is round-trip:
// parse(print(v)) yields a value eq to v. That drives the fiddly cases — doubles
// print as re-parseable doubles, and symbols print bare only when they would lex
// back unchanged.

import { BasslineVisitor, isValue } from '../data.js'

// Characters that end a bare token (whitespace + the structural delimiters).
const DELIM = new Set([
  ' ',
  '\t',
  '\n',
  '\r',
  '[',
  ']',
  '{',
  '}',
  '<',
  '>',
  '(',
  ')',
  ':',
  '#',
  "'",
  '"',
  '`',
])
const RESERVED = new Set([
  'nil',
  'true',
  'false',
  'NaN',
  'Infinity',
  '-Infinity',
])
const isDigit = c => c >= '0' && c <= '9'

/**
 * A symbol prints bare iff it lexes back as exactly that one symbol.
 * @param s
 */
function bareSafe(s) {
  if (s.length === 0 || RESERVED.has(s)) return false
  if (isDigit(s[0]) || ((s[0] === '+' || s[0] === '-') && isDigit(s[1])))
    return false
  for (const ch of s) if (DELIM.has(ch)) return false
  return true
}

/**
 * Escape a string/quoted-symbol body for the given closing quote.
 * @param s
 * @param quote
 */
function escapeBody(s, quote) {
  let out = ''
  for (const ch of s) {
    if (ch === quote) out += '\\' + quote
    else if (ch === '\\') out += '\\\\'
    else if (ch === '\n') out += '\\n'
    else if (ch === '\t') out += '\\t'
    else if (ch === '\r') out += '\\r'
    else out += ch
  }
  return out
}

/**
 * A double, formatted so it re-parses as the same double (never an integer).
 * @param x
 */
function formatFloat(x) {
  if (Number.isNaN(x)) return 'NaN'
  if (x === Infinity) return 'Infinity'
  if (x === -Infinity) return '-Infinity'
  if (Object.is(x, -0)) return '-0.0'
  const s = String(x) // shortest round-tripping decimal
  return /[.e]/i.test(s) ? s : s + '.0' // force a fractional part so it isn't an int
}

function hex(u8) {
  let s = ''
  for (const b of u8) s += b.toString(16).padStart(2, '0').toUpperCase()
  return s
}

export class BasslinePP extends BasslineVisitor {
  str = ''
  depth = 0
  padding = 2

  write(s) {
    this.str += s
  }

  /** A newline followed by the current indentation. */
  break() {
    this.str += '\n' + ' '.repeat(this.depth * this.padding)
  }

  /**
   * open, then one indented line per item, then close — or `openclose` if empty.
   * @param open
   * @param items
   * @param close
   * @param render
   */
  frame(open, items, close, render = x => this.visit(x)) {
    if (items.length === 0) return this.write(open + close)
    this.write(open)
    this.depth++
    for (const item of items) {
      this.break()
      render(item)
    }
    this.depth--
    this.break()
    this.write(close)
  }

  visit(aValue) {
    if (aValue.actionable) this.write('`')
    return super.visit(aValue)
  }

  visitNil() {
    this.write('nil')
  }
  visitBool(aBool) {
    this.write(aBool.value ? 'true' : 'false')
  }
  visitInt(anInt) {
    this.write(anInt.value.toString())
  }
  visitFloat(aFloat) {
    this.write(formatFloat(aFloat.value))
  }
  visitString(aString) {
    this.write('"' + escapeBody(aString.value, '"') + '"')
  }
  visitSymbol(aSymbol) {
    const s = aSymbol.value
    this.write(bareSafe(s) ? s : "'" + escapeBody(s, "'") + "'")
  }
  visitBytes(aBytes) {
    this.write('#[' + hex(aBytes.value) + ']')
  }
  visitList(aList) {
    this.frame('[', aList.value, ']')
  }
  visitSet(aSet) {
    this.frame('#{', aSet.value, '}')
  }
  visitDict(aDict) {
    this.frame('{', aDict.value, '}', ([k, v]) => {
      this.visit(k)
      this.write(': ')
      this.visit(v)
    })
  }
  visitRecord(aRecord) {
    const { head, fields } = aRecord.value
    if (fields.length === 0) {
      this.write('<')
      this.visit(head)
      return this.write('>')
    }
    this.write('<')
    this.visit(head)
    this.depth++
    for (const f of fields) {
      this.break()
      this.visit(f)
    }
    this.depth--
    this.break()
    this.write('>')
  }

  toString() {
    return this.str
  }
}

/**
 * Pretty-print a value to text. parse(print(v))[0] is eq to v.
 * @param v
 */
export function print(v) {
  if (!isValue(v)) throw new TypeError('expected a Bassline value')
  const pp = new BasslinePP()
  pp.visit(v)
  return pp.toString()
}
