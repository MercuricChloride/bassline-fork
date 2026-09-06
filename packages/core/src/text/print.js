// @ts-check
// Pretty-printer for the Bassline textual syntax. `flat` renders any value on
// one line; the Printer visitor lays frames out within a width, breaking a
// frame across lines only when its flat form would not fit.

/**
 * @import {
 *   Value, Atom, Frame, BList, BRecord, BDict, BSet,
 * } from '../value/value.js'
 */
import { assertValue } from '../value/value.js'
import { Visitor } from '../value/visitor.js'

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
  "'",
  '"',
  ';',
  '!',
])

/** @param {string | undefined} c */
const isDigit = c => c !== undefined && /[0-9]/.test(c)

/**
 * Whether a symbol spelling lexes back unchanged with no quotes.
 * @param {string} s
 */
function bareSafe(s) {
  if (s.length === 0 || s === 'nil') return false // nil is a reserved spelling
  if (isDigit(s[0]) || (s[0] === '-' && isDigit(s[1]))) return false
  for (const ch of s) if (DELIM.has(ch)) return false
  return true
}

/**
 * Escape the closing quote and the backslash; everything else is held
 * literally (raw newlines and tabs re-read inside quotes).
 * @param {string} s
 * @param {string} quote
 */
function escapeBody(s, quote) {
  let out = ''
  for (const ch of s) {
    if (ch === quote || ch === '\\') out += '\\'
    out += ch
  }
  return out
}

/** @param {Uint8Array} u8 */
function hex(u8) {
  let s = ''
  for (const b of u8) s += b.toString(16).padStart(2, '0')
  return s
}

/**
 * The bare one-line rendering of a value's kind, mark aside.
 * @param {Value} v
 * @returns {string}
 */
function flatten(v) {
  switch (v.kind) {
    case 'nil':
      return 'nil'
    case 'number':
      return String(v.value)
    case 'text':
      return '"' + escapeBody(v.value, '"') + '"'
    case 'symbol':
      return bareSafe(v.value) ? v.value : "'" + escapeBody(v.value, "'") + "'"
    case 'bytes':
      return '0x' + hex(v.value)
    case 'list':
      return '[' + v.items.map(flat).join(' ') + ']'
    case 'record':
      return '(' + v.items.map(flat).join(' ') + ')'
    case 'set':
      return '{' + [...v.values()].map(flat).join(' ') + '}'
    case 'dict':
      return v.size === 0
        ? '{:}'
        : '{' +
            [...v.entries()]
              .map(([k, val]) => flat(k) + ': ' + flat(val))
              .join(' ') +
            '}'
  }
}

/**
 * One-line rendering of a value with its mark: a frame is marked in front
 * (`!(…)`), an atom behind (`x!`).
 * @param {Value} v
 * @returns {string}
 */
function flat(v) {
  const s = flatten(v)
  if (!v.mark) return s
  return v.isFrame() ? '!' + s : s + '!'
}

/**
 * Lays a value out within a width. State — the output so far and the current
 * indent — lives on the instance; each visit hook appends to it.
 */
class Printer extends Visitor {
  #out = ''
  #depth = 0
  #width
  #padding

  /**
   * @param {number} width
   * @param {number} padding
   */
  constructor(width, padding) {
    super()
    this.#width = width
    this.#padding = padding
  }

  /** @param {Value} value */
  run(value) {
    value.accept(this)
    return this.#out
  }

  #column() {
    return this.#out.length - (this.#out.lastIndexOf('\n') + 1)
  }
  /** @param {string} s */
  #write(s) {
    this.#out += s
  }
  #br() {
    this.#write('\n' + ' '.repeat(this.#depth * this.#padding))
  }

  /**
   * Write `node` flat if it fits the remaining width, else write its mark then
   * run `emitBroken`. An empty frame always prints flat — a broken `{}` would
   * lose the set / dict distinction.
   * @param {Frame} node
   * @param {() => void} emitBroken
   */
  #compound(node, emitBroken) {
    const s = flat(node)
    if (node.size === 0 || this.#column() + s.length <= this.#width) {
      return this.#write(s)
    }
    if (node.mark) this.#write('!')
    emitBroken()
  }

  /**
   * A run of items between delimiters, one per line, indented.
   * @template T
   * @param {string} open
   * @param {string} close
   * @param {Iterable<T>} items
   * @param {(item: T) => void} render
   */
  #block(open, close, items, render) {
    this.#write(open)
    this.#depth++
    for (const item of items) {
      this.#br()
      render(item)
    }
    this.#depth--
    this.#br()
    this.#write(close)
  }

  /** @param {Atom} v */
  visitAtom(v) {
    this.#write(flat(v))
  }

  /** @param {BList} v */
  visitList(v) {
    this.#compound(v, () =>
      this.#block('[', ']', v.items, item => item.accept(this))
    )
  }

  /** @param {BSet} v */
  visitSet(v) {
    this.#compound(v, () =>
      this.#block('{', '}', v.values(), item => item.accept(this))
    )
  }

  /** @param {BDict} v */
  visitDict(v) {
    this.#compound(v, () =>
      this.#block('{', '}', v.entries(), ([k, val]) => {
        k.accept(this)
        this.#write(': ')
        val.accept(this)
      })
    )
  }

  /** @param {BRecord} v */
  visitRecord(v) {
    this.#compound(v, () => {
      const [head, ...fields] = v.items
      this.#write('(' + flat(head))
      this.#depth++
      for (const f of fields) {
        this.#br()
        f.accept(this)
      }
      this.#depth--
      this.#br()
      this.#write(')')
    })
  }
}

/**
 * Pretty-print a value to Bassline textual syntax.
 * @param {Value} value
 * @param {number} [width]
 * @param {number} [padding]
 */
export function print(value, width = 72, padding = 2) {
  assertValue(value, 'print expects a Bassline value')
  return new Printer(width, padding).run(value)
}
