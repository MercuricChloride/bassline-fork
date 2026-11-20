import {
  spelling,
  type FrameKind,
  type Value,
  isFrame,
  type Frame,
} from '../types.ts'

const DELIMS = new Set([
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
const isDigit = (c: string | undefined) =>
  c !== undefined && c >= '0' && c <= '9'

/**
 * Whether a symbol may be spelled without quotes: it has to read back as
 * itself — not empty, not nil, not a number or bytes, and free of delimiters
 * and control characters.
 */
function isBareSpelling(s: string) {
  if (s.length === 0 || s === 'nil') return false
  if (isDigit(s[0]) || (s[0] === '-' && isDigit(s[1]))) return false
  for (const c of s) {
    if (DELIMS.has(c) || c < ' ') return false
  }
  return true
}

/** The reader's escapes, \q \\ \n \t \r, so an atom is one line. */
function escaped(s: string, q: string) {
  let out = ''
  for (const c of s) {
    if (c === '\\') out += '\\\\'
    else if (c === '\n') out += '\\n'
    else if (c === '\t') out += '\\t'
    else if (c === '\r') out += '\\r'
    else out += c === q ? '\\' + c : c
  }
  return out
}

function hex(b: Uint8Array) {
  let out = '0x'
  for (const x of b) out += x.toString(16).padStart(2, '0')
  return out
}

function atom(v: Value): string {
  let out: string
  switch (v.kind) {
    case 'nil':
      out = 'nil'
      break
    case 'number':
      out = spelling(v.payload)
      break
    case 'symbol':
      out = isBareSpelling(v.payload)
        ? v.payload
        : `'${escaped(v.payload, "'")}'`
      break
    case 'text':
      out = `"${escaped(v.payload, '"')}"`
      break
    case 'bytes':
      out = hex(v.payload)
      break
    default:
      throw new TypeError('not an atom: ' + v.kind)
  }
  return v.mark ? out + '!' : out
}

function opener(v: Frame) {
  const b = v.kind === 'list' ? '[' : v.kind === 'record' ? '(' : '{'
  return v.mark ? '!' + b : b
}

function closer(v: Frame) {
  return v.kind === 'list' ? ']' : v.kind === 'record' ? ')' : '}'
}

/** The members of a list, record or set. */
function members(v: Frame): Value[] {
  return v.kind === 'list' || v.kind === 'record'
    ? [...v.items]
    : [...v.children()]
}

/** The width of the one-line spelling, stopping early past `room`. */
function flatLen(v: Value, room: number): number {
  if (!isFrame(v)) return atom(v).length
  let n = opener(v).length + 1
  if (v.kind === 'dict') {
    if (v.length === 0) return n + 1 // {:}
    let first = true
    for (const [k, x] of v.entries()) {
      if (!first) n++
      first = false
      n += flatLen(k, room - n) + 2 // ': '
      n += flatLen(x, room - n)
      if (n > room) return n
    }
    return n
  }
  let first = true
  for (const m of members(v)) {
    if (!first) n++
    first = false
    n += flatLen(m, room - n)
    if (n > room) return n
  }
  return n
}

class Out {
  s = ''
  /** Where the next character lands on the current line. */
  get column() {
    return this.s.length - (this.s.lastIndexOf('\n') + 1)
  }
  add(t: string) {
    this.s += t
  }
  newline(align: number) {
    this.s += '\n' + ' '.repeat(align)
  }
}

function putFlat(o: Out, v: Value) {
  if (!isFrame(v)) return o.add(atom(v))
  o.add(opener(v))
  if (v.kind === 'dict') {
    if (v.length === 0) o.add(':')
    let first = true
    for (const [k, x] of v.entries()) {
      if (!first) o.add(' ')
      first = false
      putFlat(o, k)
      o.add(': ')
      putFlat(o, x)
    }
  } else {
    let first = true
    for (const m of members(v)) {
      if (!first) o.add(' ')
      first = false
      putFlat(o, m)
    }
  }
  o.add(closer(v))
}

/**
 * The members of a list, set or record (past its head): the first at the
 * current column, the rest aligned with it, as many to a line as fit when all
 * are atoms, otherwise one to a line.
 */
function putMembers(
  o: Out,
  ms: Value[],
  align: number,
  width: number,
  trail: number
) {
  const fill = ms.every(m => !isFrame(m))
  ms.forEach((m, i) => {
    const after = i === ms.length - 1 ? 1 + trail : 0 // the closers to come
    if (i > 0) {
      if (fill && o.column + 1 + atom(m).length + after <= width) o.add(' ')
      else o.newline(align)
    }
    put(o, m, width, after)
  })
}

/**
 * `v` at the current column: flat when it fits with `trail` characters still
 * to come on its last line, else opened.
 */
function put(o: Out, v: Value, width: number, trail: number) {
  if (!isFrame(v) || width === Infinity || v.length === 0) return putFlat(o, v)
  const col = o.column
  if (col + flatLen(v, width - col - trail) + trail <= width)
    return putFlat(o, v)
  o.add(opener(v))
  if (v.kind === 'dict') {
    const align = o.column
    let i = 0
    for (const [k, x] of v.entries()) {
      if (i > 0) o.newline(align)
      put(o, k, width, 2)
      o.add(': ')
      put(o, x, width, i === v.length - 1 ? 1 + trail : 0)
      i++
    }
  } else if (v.kind === 'record') {
    const only = v.items.length === 1
    put(o, v.head, width, only ? 1 + trail : 0)
    if (!only) {
      let align = o.column + 1
      if (align > width / 2) {
        // the head is too wide to align after, so members go under it
        align = col + opener(v).length
        o.newline(align)
      } else o.add(' ')
      putMembers(o, v.fields, align, width, trail)
    }
  } else {
    putMembers(o, members(v), o.column, width, trail)
  }
  o.add(closer(v))
}

/** `v` laid out within `width` columns. It reads back as `v`. */
export function pretty(v: Value, width = 80): string {
  const o = new Out()
  put(o, v, width, 0)
  return o.s
}

/** `v` on one line. It reads back as `v`. */
export function print(v: Value): string {
  return pretty(v, Infinity)
}
