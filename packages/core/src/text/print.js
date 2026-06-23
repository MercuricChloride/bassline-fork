// A Pretty-printer from Bassline Values to the Bassline textual syntax
//
// The output is guaranteed to round-trip:
// read(print(v)) yields a value eq to v.
//
// The Layout is width-aware: a node is rendered flat (one line) when it fits the
// remaining width, and only broken across indented lines when it doesn't. So a
// `<cell A1 "Rent">` stays inline while a big `<sheet ..>` breaks one cell per
// line — each of those cells then re-deciding flat-or-break on its own.

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

// The single-line ("flat") rendering of a value — the inline form, and the
// measuring stick the pretty-printer uses to decide whether to break.
class Flat extends BasslineVisitor {
  visit(v) {
    return (v.actionable ? '`' : '') + super.visit(v)
  }
  visitNil() {
    return 'nil'
  }
  visitBool(b) {
    return b.value ? 'true' : 'false'
  }
  visitInt(i) {
    return i.value.toString()
  }
  visitFloat(f) {
    return formatFloat(f.value)
  }
  visitString(s) {
    return '"' + escapeBody(s.value, '"') + '"'
  }
  visitSymbol(s) {
    return bareSafe(s.value) ? s.value : "'" + escapeBody(s.value, "'") + "'"
  }
  visitBytes(b) {
    return '#[' + hex(b.value) + ']'
  }
  visitList(l) {
    return '[' + l.value.map(x => this.visit(x)).join(' ') + ']'
  }
  visitSet(s) {
    return (
      '#{' +
      Array.from(s.value.values())
        .map(x => this.visit(x))
        .join(' ') +
      '}'
    )
  }
  visitRecord(r) {
    const [head, ...fields] = r.value
    return '<' + [head, ...fields].map(x => this.visit(x)).join(' ') + '>'
  }
  visitDict(d) {
    const entries = Array.from(d.value.values()).map(
      ([k, v]) => this.visit(k) + ': ' + this.visit(v)
    )
    return '{' + entries.join(' ') + '}'
  }
}

const FLAT = new Flat()
const flat = v => FLAT.visit(v)

export class BasslinePP extends BasslineVisitor {
  str = ''
  depth = 0
  padding = 2
  width = 72

  constructor(width = 72) {
    super()
    this.width = width
  }

  write(s) {
    this.str += s
  }

  /** Columns written on the current (last) line. */
  column() {
    return this.str.length - (this.str.lastIndexOf('\n') + 1)
  }

  /** A newline followed by the current indentation. */
  break() {
    this.str += '\n' + ' '.repeat(this.depth * this.padding)
  }

  /**
   * Write `node` flat if it fits the line; otherwise run `emitBroken`.
   * @param node
   * @param emitBroken
   */
  compound(node, emitBroken) {
    const s = flat(node)
    if (this.column() + s.length <= this.width) return this.write(s)
    if (node.actionable) this.write('`')
    emitBroken()
  }

  /**
   * A frame broken across lines: open, one indented item per line, close.
   * @param node
   * @param open
   * @param close
   * @param items
   * @param renderItem
   */
  block(node, open, close, items, renderItem = x => this.visit(x)) {
    this.compound(node, () => {
      this.write(open)
      this.depth++
      for (const item of items) {
        this.break()
        renderItem(item)
      }
      this.depth--
      this.break()
      this.write(close)
    })
  }

  visitNil(v) {
    this.write(flat(v))
  }
  visitBool(v) {
    this.write(flat(v))
  }
  visitInt(v) {
    this.write(flat(v))
  }
  visitFloat(v) {
    this.write(flat(v))
  }
  visitString(v) {
    this.write(flat(v))
  }
  visitSymbol(v) {
    this.write(flat(v))
  }
  visitBytes(v) {
    this.write(flat(v))
  }
  visitList(aList) {
    this.block(aList, '[', ']', aList.value)
  }
  visitSet(aSet) {
    this.block(aSet, '#{', '}', Array.from(aSet.value.values()))
  }
  visitDict(aDict) {
    this.block(aDict, '{', '}', Array.from(aDict.value.values()), ([k, v]) => {
      this.visit(k)
      this.write(': ')
      this.visit(v)
    })
  }
  visitRecord(aRecord) {
    const [head, ...fields] = aRecord.value
    this.compound(aRecord, () => {
      this.write('<' + flat(head)) // head stays inline on the open line
      this.depth++
      for (const f of fields) {
        this.break()
        this.visit(f)
      }
      this.depth--
      this.break()
      this.write('>')
    })
  }

  toString() {
    return this.str
  }
}

/**
 * Pretty-print a value to text. parse(print(v))[0] is eq to v.
 * @param v
 * @param {number} [width] line width that triggers breaking (default 72)
 */
export function print(v, width = 72) {
  if (!isValue(v)) throw new TypeError('expected a Bassline value')
  const pp = new BasslinePP(width)
  pp.visit(v)
  return pp.toString()
}
