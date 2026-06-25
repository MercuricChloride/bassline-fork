/** @import {Value} from "../data.js" */
import { generic } from '../data.js'

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

const isDigit = c => /[0-9]/.test(c)

/**
 * @param {string} s
 */
function bareSafe(s) {
  if (s.length === 0 || RESERVED.has(s)) return false
  if (isDigit(s[0]) || ((s[0] === '+' || s[0] === '-') && isDigit(s[1])))
    return false
  for (const ch of s) if (DELIM.has(ch)) return false
  return true
}

/**
 * @param {string} s
 * @param {string} quote
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
 * A double formatted so it re-parses as the same double (never an integer).
 * @param {number} x
 */
function formatFloat(x) {
  if (Number.isNaN(x)) return 'NaN'
  if (x === Infinity) return 'Infinity'
  if (x === -Infinity) return '-Infinity'
  if (Object.is(x, -0)) return '-0.0'
  const s = String(x) // shortest round-tripping decimal
  return /[.e]/i.test(s) ? s : s + '.0' // force a fractional part so it isn't an int
}

/** @param {Uint8Array} u8 */
function hex(u8) {
  let s = ''
  for (const b of u8) s += b.toString(16).padStart(2, '0').toUpperCase()
  return s
}

/**
 * The bare one-line rendering of each value kind. Frames recurse through `flat`
 * (not `flatten`) so nested actionable values keep their backtick prefix.
 * @type {(v: Value) => string}
 */
const flatten = generic({
  nil: () => 'nil',
  bool: v => (v.value ? 'true' : 'false'),
  int: v => v.value.toString(),
  float: v => formatFloat(v.value),
  string: v => '"' + escapeBody(v.value, '"') + '"',
  symbol: v =>
    bareSafe(v.value) ? v.value : "'" + escapeBody(v.value, "'") + "'",
  bytes: v => '#[' + hex(v.value) + ']',
  list: v => '[' + v.value.map(x => flat(x)).join(' ') + ']',
  set: v =>
    '#{' +
    Array.from(v.value.values())
      .map(x => flat(x))
      .join(' ') +
    '}',
  record: v => '<' + v.value.map(x => flat(x)).join(' ') + '>',
  dict: v =>
    '{' +
    Array.from(v.value.values())
      .map(([k, val]) => flat(k) + ': ' + flat(val))
      .join(' ') +
    '}',
})

/**
 * One-line rendering of a value, prefixed with the actionable backtick.
 * @param {Value} v
 */
function flat(v) {
  return v.actionable ? '`' + flatten(v) : flatten(v)
}

/**
 * Pretty-print a value to Bassline textual syntax
 * @param {Value} value
 * @param {number} width
 * @param {number} padding
 */
export function print(value, width = 72, padding = 2) {
  let str = ''
  let depth = 0

  const column = () => str.length - (str.lastIndexOf('\n') + 1)
  const write = s => (str += s)
  const br = () => write('\n' + ' '.repeat(depth * padding))

  const visit = generic(
    {
      list: v => compound(v, () => block('[', ']', v.value)),
      set: v => compound(v, () => block('#{', '}', [...v.value.values()])),
      dict: v =>
        compound(v, () =>
          block('{', '}', [...v.value.values()], ([k, val]) => {
            visit(k)
            write(': ')
            visit(val)
          })
        ),
      record: v =>
        compound(v, () => {
          const [head, ...fields] = v.value
          write('<' + flat(head))
          depth++
          for (const f of fields) {
            br()
            visit(f)
          }
          depth--
          br()
          write('>')
        }),
    },
    v => write(flat(v))
  )

  visit(value)
  return str

  /**
   * Prints flat if it fits the remaining print width, else prints the actionable prefix and calls emitBroken to print the broken form.
   * @param {Value} node
   * @param {() => void} emitBroken
   */
  function compound(node, emitBroken) {
    const s = flat(node)
    if (column() + s.length <= width) return write(s)
    if (node.actionable) write('`')
    emitBroken()
  }

  /**
   * Renders a block of values with the given opening and closing delimiters.
   * @param {string} open
   * @param {string} close
   * @param {Iterable<Value>} items
   * @param {(item: Value) => void} renderItem
   */
  function block(open, close, items, renderItem = visit) {
    write(open)
    depth++
    for (const item of items) {
      br()
      renderItem(item)
    }
    depth--
    br()
    write(close)
  }
}
