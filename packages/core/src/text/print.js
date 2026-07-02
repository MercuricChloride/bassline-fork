/** @import {Value} from "../data.js" */

const DELIM = new Set([
  ' ',
  '\t',
  '\n',
  '\r',
  '[',
  ']',
  '{',
  '}',
  '(',
  ')',
  ':',
  '#',
  "'",
  '"',
  '`',
  ';',
])

const isDigit = c => /[0-9]/.test(c)

/**
 * @param {string} s
 */
function bareSafe(s) {
  // nil is a reserved spelling
  if (s.length === 0 || s === 'nil') return false
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
    else if (ch === '\t') out += '\\t'
    else if (ch === '\r') out += '\\r'
    else out += ch // newlines are emitted literally; they re-read inside quotes
  }
  return out
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
 * @param {Value} v
 * @returns {string}
 */
function flatten(v) {
  switch (v.kind) {
    case 'nil':
      return 'nil'
    case 'int':
      return v.value.toString()
    case 'string':
      return '"' + escapeBody(v.value, '"') + '"'
    case 'symbol':
      return bareSafe(v.value) ? v.value : "'" + escapeBody(v.value, "'") + "'"
    case 'bytes':
      return '#[' + hex(v.value) + ']'
    case 'list':
      return '[' + v.value.map(flat).join(' ') + ']'
    case 'set':
      return '#{' + v.value.map(flat).join(' ') + '}'
    case 'record':
      return '(' + v.value.map(flat).join(' ') + ')'
    case 'dict':
      return (
        '{' +
        v.value.map(([k, val]) => flat(k) + ': ' + flat(val)).join(' ') +
        '}'
      )
  }
}

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

  /** @param {Value} v */
  function visit(v) {
    switch (v.kind) {
      case 'list':
        return compound(v, () => block('[', ']', v.value))
      case 'set':
        return compound(v, () => block('#{', '}', v.value))
      case 'dict':
        return compound(v, () =>
          block('{', '}', v.value, ([k, val]) => {
            visit(k)
            write(': ')
            visit(val)
          })
        )
      case 'record':
        return compound(v, () => {
          const [head, ...fields] = v.value
          write('(' + flat(head))
          depth++
          for (const f of fields) {
            br()
            visit(f)
          }
          depth--
          br()
          write(')')
        })
      default:
        return write(flat(v))
    }
  }

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
   * @template T
   * @param {string} open
   * @param {string} close
   * @param {Iterable<T>} items
   * @param {(item: T) => void} [renderItem]
   */
  function block(open, close, items, renderItem) {
    const render = renderItem ?? /** @type {(item: T) => void} */ (visit)
    write(open)
    depth++
    for (const item of items) {
      br()
      render(item)
    }
    depth--
    br()
    write(close)
  }
}
