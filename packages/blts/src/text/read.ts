import { integer, MAX_DEPTH } from '../codec/util.ts'
import type { Factory, Value } from '../types.ts'

/** Text that breaks a rule of the syntax. */
export class ReadError extends Error {
  readonly line: number
  readonly col: number
  constructor(message: string, line: number, col: number) {
    super(`line ${line}, col ${col}: ${message}`)
    this.line = line
    this.col = col
  }
}

/** Text that runs out inside a value, having broken no rule. */
export class ReadIncomplete extends ReadError {}

/** The text fed so far ends here, and more may come. */
const STARVED = Symbol('starved')

const WS = new Set([' ', '\t', '\n', '\r'])
const DELIMS = new Set([
  ...WS,
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
const OPENERS = new Set(['(', '[', '{'])
const CANONICAL = /^(0|-?[1-9][0-9]*)$/

const isDigit = (c: string | undefined) =>
  c !== undefined && c >= '0' && c <= '9'
const isHex = (c: string | undefined) =>
  c !== undefined &&
  (isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))

export type ReaderOptions = {
  /** How deep frames may nest. */
  maxDepth?: number
}

/** Where a piece of text begins, counted from 1. */
type Origin = { line: number; col: number }

function advance(o: Origin, text: string, upto: number): Origin {
  let { line, col } = o
  for (let i = 0; i < upto && i < text.length; i++) {
    if (text[i] === '\n') {
      line++
      col = 1
    } else col++
  }
  return { line, col }
}

/**
 * One reading of the text from `pos`. Until the text is final, reaching its
 * end starves, so a pause is never taken for a delimiter.
 */
class Parser {
  readonly make: Factory
  readonly text: string
  readonly final: boolean
  readonly origin: Origin
  readonly maxDepth: number
  pos: number
  /** How many frames are open around pos. */
  depth = 0

  constructor(
    make: Factory,
    text: string,
    final: boolean,
    pos: number,
    origin: Origin,
    maxDepth: number
  ) {
    this.make = make
    this.text = text
    this.final = final
    this.pos = pos
    this.origin = origin
    this.maxDepth = maxDepth
  }

  /** Whether `at` is past the end of the text; starves if more may come. */
  past(at = this.pos): boolean {
    if (at < this.text.length) return false
    if (!this.final) throw STARVED
    return true
  }

  at(at = this.pos) {
    return this.text[at]!
  }

  fail(at: number, msg: string): never {
    const { line, col } = advance(this.origin, this.text, at)
    throw new ReadError(msg, line, col)
  }

  incomplete(at: number, msg: string): never {
    const { line, col } = advance(this.origin, this.text, at)
    throw new ReadIncomplete(msg, line, col)
  }

  /** Whitespace and comments. Starving in a comment leaves pos on its ';'. */
  skipWs() {
    while (!this.past()) {
      const c = this.at()
      if (c === ';') {
        let eol = this.pos
        while (!this.past(eol) && this.text[eol] !== '\n') eol++
        this.pos = eol
      } else if (WS.has(c)) this.pos++
      else break
    }
  }

  value(): Value {
    this.skipWs()
    if (this.past()) this.incomplete(this.pos, 'expected a value')
    let marked = false
    if (this.at() === '!') {
      // a mark in front belongs to a frame; it must touch the bracket
      this.pos++
      if (this.past()) this.incomplete(this.pos, 'mark with no value')
      const c = this.at()
      if (c === '!') this.fail(this.pos, 'repeated mark')
      if (WS.has(c) || c === ';')
        this.fail(this.pos, 'mark separated from its value')
      if (!OPENERS.has(c)) {
        this.fail(
          this.pos,
          'only a frame is marked in front; an atom is marked behind: x!'
        )
      }
      marked = true
    }
    if (OPENERS.has(this.at())) {
      const v = this.frame(marked)
      if (!this.past() && this.at() === '!') {
        this.fail(this.pos, 'a frame is marked in front: !(…)')
      }
      return v
    }
    const build = this.atom()
    if (!this.past() && this.at() === '!') {
      // a mark behind belongs to an atom; it must touch the atom and end at
      // a delimiter
      this.pos++
      if (!this.past() && !DELIMS.has(this.at())) {
        this.fail(this.pos, 'a marked atom ends at a delimiter')
      }
      marked = true
    }
    return build(marked)
  }

  /**
   * The frame at pos, its mark already read. Frames are read by recursion, so
   * the depth limit is what keeps deep text off the call stack.
   */
  frame(mark: boolean): Value {
    if (this.depth >= this.maxDepth)
      this.fail(this.pos, `frames nest past ${this.maxDepth}`)
    this.depth++
    const v = this.frameBody(mark)
    this.depth--
    return v
  }

  frameBody(mark: boolean): Value {
    const make = this.make
    switch (this.at()) {
      case '[':
        this.pos++
        return make.list(this.members(']'), mark)
      case '(': {
        this.pos++
        this.skipWs()
        if (this.past()) this.incomplete(this.pos, 'unclosed (')
        if (this.at() === ')') this.fail(this.pos, 'record with no head')
        const head = this.value()
        return make.record([head, ...this.members(')')], mark)
      }
      default:
        return this.braces(mark)
    }
  }

  /** The atom at pos, built once its mark is known. */
  atom(): (mark: boolean) => Value {
    const make = this.make
    const c = this.at()
    switch (c) {
      case '"': {
        const s = this.quoted('"')
        return m => make.text(s, m)
      }
      case "'": {
        const s = this.quoted("'")
        return m => make.sym(s, m)
      }
      case ')':
      case ']':
      case '}':
      case ':':
      case '!':
        this.fail(this.pos, 'unexpected ' + c)
    }
    return this.bare()
  }

  /** Values up to the closer, which is passed over. */
  members(close: string): Value[] {
    const out: Value[] = []
    for (;;) {
      this.skipWs()
      if (this.past())
        this.incomplete(this.pos, 'unclosed ' + (close === ']' ? '[' : '('))
      if (this.at() === close) {
        this.pos++
        return out
      }
      out.push(this.value())
    }
  }

  /**
   * {} is the empty set, {:} the empty dict; otherwise the first member
   * decides: a ':' after it makes the frame a dictionary. The members go to
   * the factory as written, and the frame it builds puts them in order; one
   * holding fewer than were written was given one twice.
   */
  braces(mark: boolean): Value {
    const make = this.make
    const start = this.pos
    const closed = () => {
      this.skipWs()
      if (this.past()) this.incomplete(this.pos, 'unclosed {')
    }
    const once = (v: Value, written: number, what: string) => {
      if (v.length !== written) this.fail(start, 'duplicate ' + what)
      return v
    }
    this.pos++
    closed()
    if (this.at() === '}') {
      this.pos++
      return make.set([], mark)
    }
    if (this.at() === ':') {
      this.pos++
      closed()
      if (this.at() !== '}')
        this.fail(this.pos, "'{:' is the empty dictionary; expected '}'")
      this.pos++
      return make.dict([], mark)
    }
    const first = this.value()
    closed()
    if (this.at() === ':') {
      const entries: [Value, Value][] = []
      for (let k = first; ; ) {
        this.pos++ // the ':'
        entries.push([k, this.value()])
        closed()
        if (this.at() === '}') break
        k = this.value()
        this.skipWs()
        if (this.past())
          this.incomplete(this.pos, "dict entry needs ':' after its key")
        if (this.at() !== ':')
          this.fail(this.pos, "dict entry needs ':' after its key")
      }
      this.pos++
      return once(make.dict(entries, mark), entries.length, 'dict key')
    }
    const members = [first]
    for (;;) {
      closed()
      if (this.at() === '}') break
      if (this.at() === ':')
        this.fail(this.pos, "':' in a set; a dictionary is {key: value}")
      members.push(this.value())
    }
    this.pos++
    return once(make.set(members, mark), members.length, 'set member')
  }

  /** The body of a "string" or 'symbol' where pos is on its opening quote. */
  quoted(q: string): string {
    const what = q === '"' ? 'text' : 'symbol'
    const start = this.pos
    let out = ''
    let i = start + 1
    let from = i
    for (;;) {
      if (this.past(i)) this.incomplete(i, 'unterminated ' + what)
      const c = this.text[i]
      if (c === q) break
      if (c !== '\\') {
        i++
        continue
      }
      if (this.past(i + 1)) this.incomplete(i, 'unterminated ' + what)
      const e = this.text[i + 1]!
      const r = ESCAPES.get(e) ?? (e === q ? q : undefined)
      if (r === undefined) this.fail(i, `unknown escape \\${e} in ${what}`)
      out += this.text.slice(from, i) + r
      i += 2
      from = i
    }
    out += this.text.slice(from, i)
    this.pos = i + 1
    if (!out.isWellFormed()) this.fail(start, 'a lone surrogate in ' + what)
    return out
  }

  /** A run of non-delimiters: bytes, a number, nil or a bare symbol. */
  bare(): (mark: boolean) => Value {
    const make = this.make
    const start = this.pos
    let i = start
    while (!this.past(i) && !DELIMS.has(this.text[i]!)) i++
    const tok = this.text.slice(start, i)
    this.pos = i
    // '_' sits between two digits, as a visual separator
    const separated = (j: number, digit: (c: string | undefined) => boolean) =>
      digit(tok[j - 1]) && digit(tok[j + 1])

    if (tok.startsWith('0x')) {
      let hex = ''
      for (let j = 2; j < tok.length; j++) {
        const c = tok[j]!
        if (c === '_') {
          if (!separated(j, isHex))
            this.fail(start + j, "'_' sits between digits")
        } else if (isHex(c)) hex += c
        else this.fail(start + j, 'not a hex digit in bytes: ' + c)
      }
      if (hex.length % 2 !== 0)
        this.fail(start, 'bytes need an even count of hex digits')
      const b = Uint8Array.from({ length: hex.length / 2 }, (_, j) =>
        parseInt(hex.slice(2 * j, 2 * j + 2), 16)
      )
      return m => make.bytes(b, m)
    }
    if (isDigit(tok[0]) || (tok[0] === '-' && isDigit(tok[1]))) {
      let digits = ''
      for (let j = 0; j < tok.length; j++) {
        const c = tok[j]!
        if (c !== '_') digits += c
        else if (!separated(j, isDigit))
          this.fail(start + j, "'_' sits between digits")
      }
      if (!CANONICAL.test(digits))
        this.fail(start, 'not a canonical number: ' + tok)
      const n = integer(digits)
      return m => make.number(n, m)
    }
    if (tok === 'nil') return m => make.nil(m)
    if (!tok.isWellFormed()) this.fail(start, 'a lone surrogate in a symbol')
    return m => make.sym(tok, m)
  }
}

const ESCAPES = new Map([
  ['\\', '\\'],
  ['n', '\n'],
  ['t', '\t'],
  ['r', '\r'],
])

type ScanState = 'code' | 'deciding' | 'comment' | 'quoted' | 'escaped'

/**
 * Text read as it arrives. `add` it in pieces, pull `values()` for each value
 * the text so far certainly holds, and `finish` once no more is coming. A
 * value still open waits for more, and so does an atom touching the end of
 * the text, since the next piece may go on with it. A reader that refused
 * stays refused.
 */
export class Reader {
  readonly factory: Factory
  readonly maxDepth: number
  /** Fed and not yet dropped. */
  #text = ''
  /** Where the next value may start; all before it is read. */
  #pos = 0
  #final = false
  #origin: Origin = { line: 1, col: 1 }
  #failed: ReadError | null = null
  // how far `scan` has followed the text, and what it found there
  #scanned = 0
  #open: string[] = []
  #state: ScanState = 'code'
  #quote = ''
  /** The reading may have moved on since the text was last read. */
  #armed = false
  /** How long the unread text may grow before it is read again unarmed. */
  #retry = 0

  constructor(factory: Factory, opts: ReaderOptions = {}) {
    this.factory = factory
    this.maxDepth = opts.maxDepth ?? MAX_DEPTH
  }

  /** Whether text is held toward a value not yet read. */
  get pending() {
    for (let i = this.#pos; i < this.#text.length; ) {
      const c = this.#text[i]!
      if (c === ';') {
        const eol = this.#text.indexOf('\n', i)
        if (eol < 0) return false
        i = eol
      } else if (WS.has(c)) i++
      else return true
    }
    return false
  }

  /** More text. What is already read is dropped first, its lines kept count of. */
  add(text: string) {
    if (this.#failed) throw this.#failed
    if (this.#final) throw new Error('text added after finish')
    if (this.#pos > 0) {
      this.#origin = advance(this.#origin, this.#text, this.#pos)
      this.#text = this.#text.slice(this.#pos)
      this.#scanned -= this.#pos
      this.#pos = 0
    }
    this.#text += text
  }

  /** No more text is coming. Pull `values()` for what is left. */
  finish() {
    this.#final = true
  }

  /**
   * Each value the text fed so far certainly holds, once. A refusal comes out
   * once the text has moved on past it at the top, or at the latest once the
   * unread text has doubled. Once finished, the end of the text closes an
   * atom touching it, and a value still open is ReadIncomplete.
   */
  *values(): Generator<Value> {
    if (this.#failed) throw this.#failed
    this.#scan()
    if (
      !this.#final &&
      !this.#armed &&
      this.#text.length - this.#pos <= this.#retry
    )
      return
    for (;;) {
      const v = this.#next()
      if (v === undefined) break
      yield v
    }
    this.#armed = false
    this.#retry = 2 * (this.#text.length - this.#pos)
  }

  /**
   * The next value, if the text certainly holds one. The whitespace and ended
   * comments before it are read either way, so a long run of them is neither
   * held nor read again.
   */
  #next(): Value | undefined {
    const p = new Parser(
      this.factory,
      this.#text,
      this.#final,
      this.#pos,
      this.#origin,
      this.maxDepth
    )
    let skipping = true
    try {
      p.skipWs()
      skipping = false
      this.#pos = p.pos
      if (p.past()) return undefined
      const v = p.value()
      this.#pos = p.pos
      return v
    } catch (e) {
      if (e === STARVED) {
        if (skipping) this.#pos = p.pos
        return undefined
      }
      if (e instanceof ReadError) this.#failed = e
      throw e
    }
  }

  /**
   * Follows the new text just far enough to see where the reading may move
   * on: a delimiter outside any frame, string or comment, anything at all
   * right after a frame or string closes there or after a mark there, and a
   * closer out of place, which the reading refuses. Only then is the text
   * read again, so a long frame or string arriving in pieces is read once it
   * is whole, not on every piece.
   */
  #scan() {
    const text = this.#text
    while (this.#scanned < text.length) {
      const c = text[this.#scanned++]!
      switch (this.#state) {
        case 'comment':
          if (c === '\n') this.#state = 'code'
          break
        case 'escaped':
          this.#state = 'quoted'
          break
        case 'quoted':
          if (c === '\\') this.#state = 'escaped'
          else if (c === this.#quote)
            this.#state = this.#open.length === 0 ? 'deciding' : 'code'
          break
        default: {
          const top = this.#open.length === 0
          if (top && (this.#state === 'deciding' || DELIMS.has(c)))
            this.#armed = true
          this.#state = top && c === '!' ? 'deciding' : 'code'
          switch (c) {
            case '(':
              this.#open.push(')')
              break
            case '[':
              this.#open.push(']')
              break
            case '{':
              this.#open.push('}')
              break
            case ')':
            case ']':
            case '}':
              if (top || this.#open.at(-1) !== c) this.#armed = true
              else {
                this.#open.pop()
                if (this.#open.length === 0) this.#state = 'deciding'
              }
              break
            case '"':
            case "'":
              this.#quote = c
              this.#state = 'quoted'
              break
            case ';':
              this.#state = 'comment'
          }
        }
      }
    }
  }
}

/** Every value in text that is all there is. */
export function readDocument(
  factory: Factory,
  text: string,
  opts?: ReaderOptions
): Value[] {
  const r = new Reader(factory, opts)
  r.add(text)
  r.finish()
  return [...r.values()]
}

/**
 * Exactly one value from text that is all there is. Text that runs out inside
 * its value is ReadIncomplete. Once the value is read, anything but whitespace
 * and comments begins a second one, so the text can never be one value and is
 * refused however it ends.
 */
export function readValue(
  factory: Factory,
  text: string,
  opts: ReaderOptions = {}
): Value {
  const p = new Parser(
    factory,
    text,
    true,
    0,
    { line: 1, col: 1 },
    opts.maxDepth ?? MAX_DEPTH
  )
  p.skipWs()
  if (p.past()) p.fail(p.pos, 'expected exactly one value, got none')
  const v = p.value()
  p.skipWs()
  if (!p.past()) p.fail(p.pos, 'expected exactly one value, and more follows')
  return v
}
