/*
A port of core/nim's micro.nim. Everything a minimal bassline needs, in one
file that leans on nothing else in this package.

It reads top to bottom: limits, kinds, bytes, atom laws, numbers, sorted
arrays, values, doors, members, order, constructors, reification, reading
and writing. Everything under Sugar at the end is convenience over what
comes before it, and nothing before it leans on it.

A value is never changed once it is built. What micro.nim edits in place
returns a new value here, sharing every part that stayed the same, so
`after === before` says nothing changed.
*/

// ================
// Limits & refusals
// ================

export const MAX_DEPTH = 64
export const MAX_VALUE_BYTES = 100 * 1024 * 1024
export const MAX_ATOM_PAYLOAD = 0xffff_ffff
export const END_BYTE = 0xa0
export const MARK_BIT = 0x08

export class BasslineError extends Error {
  override name = 'BasslineError'
}

export function refuse(msg: string): never {
  throw new BasslineError(msg)
}

export function guard(cond: unknown, msg: string): asserts cond {
  if (!cond) refuse(msg)
}

// ================
// Kinds & headers
// ================

export const KINDS = [
  'nil',
  'number',
  'text',
  'symbol',
  'bytes',
  'list',
  'record',
  'dict',
  'set',
] as const

export type Kind = (typeof KINDS)[number]
export type ScalarKind = 'number' | 'text' | 'symbol' | 'bytes'
export type FrameKind = 'list' | 'record' | 'dict' | 'set'

const TAGS = Object.fromEntries(KINDS.map((k, i) => [k, i + 1])) as Record<
  Kind,
  number
>

export const tag = (kind: Kind): number => TAGS[kind]

export const isKind = (s: string): s is Kind => Object.hasOwn(TAGS, s)

export type Header =
  | { readonly part: 'close' }
  | { readonly part: 'nil'; readonly mark: boolean }
  | {
      readonly part: 'atom'
      readonly kind: ScalarKind
      readonly mark: boolean
      readonly inlineLen: number
    }
  | { readonly part: 'open'; readonly kind: FrameKind; readonly mark: boolean }

export function header(b: number): Header {
  if (b === END_BYTE) return { part: 'close' }
  const kind = KINDS[(b >> 4) - 1]
  if (kind === undefined) return refuse('invalid tag: ' + (b >> 4))
  const mark = (b & MARK_BIT) !== 0
  const inlineLen = b & 7
  switch (kind) {
    case 'nil':
      guard(inlineLen === 0, 'nil lenBits must be 0')
      return { part: 'nil', mark }
    case 'list':
    case 'record':
    case 'dict':
    case 'set':
      guard(inlineLen === 0, 'frame lenBits must be 0')
      return { part: 'open', kind, mark }
    default:
      return { part: 'atom', kind, mark, inlineLen }
  }
}

const HEADERS: readonly (Header | undefined)[] = Array.from(
  { length: 256 },
  (_, b) => {
    try {
      return header(b)
    } catch {
      return undefined
    }
  }
)

// ================
// Bytes
// ================

export function cmpBytes(a: Uint8Array, b: Uint8Array): number {
  const n = Math.min(a.length, b.length)
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) return a[i]! - b[i]!
  }
  return a.length - b.length
}

export function cmpShortlex(a: Uint8Array, b: Uint8Array): number {
  return a.length - b.length || cmpBytes(a, b)
}

function utf8Len(s: string): number {
  let n = 0
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c < 0xdc00) {
      n += 4
      i++
    } else n += 3
  }
  return n
}

// Text is held as a JS string but ordered as its UTF-8 bytes, shortlex.
// `<` on strings compares UTF-16 units, which puts U+E000 after U+10000.
// Within one UTF-8 length, byte order is code point order.
export function cmpText(a: string, b: string): number {
  if (a === b) return 0
  const d = utf8Len(a) - utf8Len(b)
  if (d !== 0) return d
  for (let i = 0; i < a.length; ) {
    const x = a.codePointAt(i)!
    const y = b.codePointAt(i)!
    if (x !== y) return x - y
    i += x > 0xffff ? 2 : 1
  }
  return 0
}

// ================
// Atom laws
// ================

const CANONICAL_INT = /^(0|-?[1-9][0-9]*)$/

export const isValidInt = (s: string): boolean => CANONICAL_INT.test(s)

// ignoreBOM keeps a leading BOM as part of the text. The default strips it.
const UTF8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true })
const ENC = new TextEncoder()

function utf8(bytes: Uint8Array): string | undefined {
  try {
    return UTF8.decode(bytes)
  } catch {
    return undefined
  }
}

export const isValidUtf8 = (bytes: Uint8Array): boolean =>
  utf8(bytes) !== undefined

// ================
// Numbers
// ================

export function cmpNums(a: bigint, b: bigint): number {
  if (a === b) return 0
  const x = a.toString()
  const y = b.toString()
  return x.length - y.length || (x < y ? -1 : 1)
}

// ================
// Sorted arrays
// ================

type Order<T> = (a: T, b: T) => number

function seek<T>(
  xs: readonly T[],
  side: (x: T) => number
): [at: number, found: boolean] {
  let lo = 0
  let hi = xs.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (side(xs[mid]!) < 0) lo = mid + 1
    else hi = mid
  }
  return [lo, lo < xs.length && side(xs[lo]!) === 0]
}

function ascending<T>(xs: readonly T[], by: Order<T>): boolean {
  for (let i = 1; i < xs.length; i++) {
    if (by(xs[i - 1]!, xs[i]!) >= 0) return false
  }
  return true
}

function sortedStrict<T>(xs: readonly T[], by: Order<T>, repeats: string): T[] {
  const sorted = xs.toSorted(by)
  guard(ascending(sorted, by), repeats)
  return sorted
}

function sortedUnique<T>(xs: Iterable<T>, by: Order<T>): T[] {
  const sorted = [...xs].sort(by)
  return sorted.filter(
    (x, i) => i === sorted.length - 1 || by(x, sorted[i + 1]!) !== 0
  )
}

// ================
// Values
// ================

export class Live {
  // JS has no address to order references by, so a live is numbered when it is made.
  static #made = 0
  readonly #serial = ++Live.#made

  static cmp(a: Live, b: Live): number {
    return a.#serial - b.#serial
  }

  reified(): Value {
    return refuse('reified must be implemented!')
  }
}

export type Node = Value | Live

export type Entry = readonly [key: Node, val: Node]

export type Value =
  | { readonly kind: 'nil'; readonly mark: boolean }
  | { readonly kind: 'number'; readonly mark: boolean; readonly num: bigint }
  | {
      readonly kind: 'text' | 'symbol'
      readonly mark: boolean
      readonly str: string
    }
  | {
      readonly kind: 'bytes'
      readonly mark: boolean
      readonly bytes: Uint8Array
    }
  | {
      readonly kind: 'list' | 'record' | 'set'
      readonly mark: boolean
      readonly items: readonly Node[]
    }
  | {
      readonly kind: 'dict'
      readonly mark: boolean
      readonly entries: readonly Entry[]
    }

export type Frame = Extract<Value, { kind: FrameKind }>
export type Atom = Exclude<Value, Frame>

// ================
// Doors
// ================

export const isBound = (n: Node): n is Live => n instanceof Live

export const isPlain = (n: Node): n is Value => !(n instanceof Live)

export function asLive(n: Node): Live {
  return n instanceof Live ? n : refuse('not live')
}

export function asValue(n: Node): Value {
  return n instanceof Live ? refuse('not data') : n
}

// ================
// Members
// ================

export const isFrame = (v: Value): v is Frame => TAGS[v.kind] >= TAGS.list

export const isAtom = (v: Value): v is Atom => !isFrame(v)

export function len(v: Value): number {
  switch (v.kind) {
    case 'list':
    case 'record':
    case 'set':
      return v.items.length
    case 'dict':
      return v.entries.length * 2
    default:
      return 0
  }
}

export function nth(v: Value, i: number): Node {
  switch (v.kind) {
    case 'list':
    case 'record':
    case 'set':
      return v.items[i] ?? refuse('invalid index')
    case 'dict':
      return v.entries[i >> 1]?.[i & 1] ?? refuse('invalid index')
    default:
      return refuse('not a frame')
  }
}

export function* members(v: Value): Generator<Node> {
  switch (v.kind) {
    case 'list':
    case 'record':
    case 'set':
      yield* v.items
      break
    case 'dict':
      for (const [key, val] of v.entries) {
        yield key
        yield val
      }
  }
}

// ================
// Order
// ================

export function cmp(a: Node, b: Node): number {
  if (a === b) return 0
  if (a instanceof Live) return b instanceof Live ? Live.cmp(a, b) : 1
  if (b instanceof Live) return -1
  if (a.kind !== b.kind) return TAGS[a.kind] - TAGS[b.kind]
  if (a.mark !== b.mark) return a.mark ? 1 : -1
  switch (a.kind) {
    case 'nil':
      return 0
    case 'number':
      return cmpNums(a.num, (b as typeof a).num)
    case 'text':
    case 'symbol':
      return cmpText(a.str, (b as typeof a).str)
    case 'bytes':
      return cmpShortlex(a.bytes, (b as typeof a).bytes)
    default: {
      const n = Math.min(len(a), len(b))
      for (let i = 0; i < n; i++) {
        const c = cmp(nth(a, i), nth(b, i))
        if (c !== 0) return c
      }
      return len(b) - len(a)
    }
  }
}

export const eq = (a: Node, b: Node): boolean => cmp(a, b) === 0

const cmpKeys = (a: Entry, b: Entry): number => cmp(a[0], b[0])

// ================
// Frame laws
// ================

export const inSetOrder = (members: readonly Node[]): boolean =>
  ascending(members, cmp)

export const inDictOrder = (entries: readonly Entry[]): boolean =>
  ascending(entries, cmpKeys)

// ================
// Constructors
// ================

export const nil = (mark = false): Value => ({ kind: 'nil', mark })

export function atom(
  kind: ScalarKind,
  payload: Uint8Array,
  mark = false
): Value {
  switch (kind) {
    case 'number': {
      const s = utf8(payload)
      guard(s !== undefined && isValidInt(s), 'not a canonical number')
      return { kind, mark, num: BigInt(s) }
    }
    case 'text':
    case 'symbol':
      return { kind, mark, str: utf8(payload) ?? refuse('invalid utf8 bytes') }
    case 'bytes':
      return { kind, mark, bytes: payload }
  }
}

export function frame(
  kind: FrameKind,
  members: readonly Node[],
  mark = false
): Value {
  switch (kind) {
    case 'list':
      return { kind, mark, items: members }
    case 'record':
      guard(members.length > 0, 'record must have a head')
      return { kind, mark, items: members }
    case 'set':
      guard(inSetOrder(members), 'set elements must be strictly ascending')
      return { kind, mark, items: members }
    case 'dict': {
      guard(members.length % 2 === 0, 'dict cannot have stranded keys')
      const entries: Entry[] = []
      for (let i = 0; i < members.length; i += 2) {
        entries.push([members[i]!, members[i + 1]!])
      }
      guard(inDictOrder(entries), 'dict keys must be strictly ascending')
      return { kind, mark, entries }
    }
  }
}

// ================
// Reification
// ================

export function isPure(n: Node): boolean {
  if (n instanceof Live) return false
  for (const m of members(n)) {
    if (!isPure(m)) return false
  }
  return true
}

function mapSame<T>(xs: readonly T[], f: (x: T) => T): readonly T[] {
  let out: T[] | undefined
  for (let i = 0; i < xs.length; i++) {
    const x = xs[i]!
    const y = f(x)
    if (y !== x) (out ??= xs.slice())[i] = y
  }
  return out ?? xs
}

function mapMembers(v: Value, f: (n: Node) => Node): Value {
  switch (v.kind) {
    case 'list':
    case 'record':
    case 'set': {
      const items = mapSame(v.items, f)
      if (items === v.items) return v
      if (v.kind !== 'set') return { ...v, items }
      const repeats = 'set normalized with duplicate elements'
      return { ...v, items: sortedStrict(items, cmp, repeats) }
    }
    case 'dict': {
      let keyChanged = false
      const entries = mapSame(v.entries, (e): Entry => {
        const key = f(e[0])
        const val = f(e[1])
        if (key !== e[0]) keyChanged = true
        return key === e[0] && val === e[1] ? e : [key, val]
      })
      if (entries === v.entries) return v
      if (!keyChanged) return { ...v, entries }
      const repeats = 'dict normalized with duplicate keys'
      return { ...v, entries: sortedStrict(entries, cmpKeys, repeats) }
    }
    default:
      return v
  }
}

export function reify(n: Node, deep = false): Value {
  if (n instanceof Live) {
    const v = n.reified()
    return deep ? reify(v, true) : v
  }
  return mapMembers(n, m => reify(m, deep))
}

// ================
// Reading
// ================

class Bytes {
  #data = new Uint8Array(64)
  #len = 0

  get length(): number {
    return this.#len
  }

  #room(n: number) {
    const need = this.#len + n
    if (need <= this.#data.length) return
    const grown = new Uint8Array(Math.max(need, this.#data.length * 2))
    grown.set(this.#data.subarray(0, this.#len))
    this.#data = grown
  }

  push(b: number) {
    this.#room(1)
    this.#data[this.#len++] = b
  }

  append(bytes: Uint8Array) {
    this.#room(bytes.length)
    this.#data.set(bytes, this.#len)
    this.#len += bytes.length
  }

  take(): Uint8Array {
    const out = this.#data.slice(0, this.#len)
    this.#len = 0
    return out
  }
}

type OpenFrame = { kind: FrameKind; mark: boolean; members: Node[] }

export type ReaderOptions = { maxDepth?: number; maxValueBytes?: number }

export class Reader {
  readonly maxDepth: number
  readonly maxValueBytes: number
  #open: OpenFrame[] = []
  #head = new Uint8Array(6)
  #headLen = 0
  #payload = new Bytes()
  #size = 0

  constructor(opts: ReaderOptions = {}) {
    this.maxDepth = opts.maxDepth ?? MAX_DEPTH
    this.maxValueBytes = opts.maxValueBytes ?? MAX_VALUE_BYTES
  }

  get starved(): boolean {
    return this.#open.length > 0 || this.#headLen > 0
  }

  #fill(src: Uint8Array, pos: number, upTo: number): number {
    while (this.#headLen < upTo && pos < src.length) {
      this.#head[this.#headLen++] = src[pos++]!
    }
    return pos
  }

  // Reads as it is pulled. Stop pulling early and the rest of src is never read.
  *read(src: Uint8Array): Generator<Value> {
    let pos = 0
    for (;;) {
      if (this.#headLen === 0) {
        if (pos >= src.length) return
        pos = this.#fill(src, pos, 1)
      }
      const h = HEADERS[this.#head[0]!] ?? header(this.#head[0]!)
      let v: Value
      let n = 1
      switch (h.part) {
        case 'open':
          guard(
            this.#open.length < this.maxDepth,
            'frames nested deeper than MaxDepth'
          )
          this.#open.push({ kind: h.kind, mark: h.mark, members: [] })
          this.#headLen = 0
          this.#size += 1
          continue
        case 'close': {
          const f = this.#open.pop() ?? refuse('end at top level')
          v = frame(f.kind, f.members, f.mark)
          break
        }
        case 'nil':
          v = nil(h.mark)
          break
        case 'atom': {
          let length = h.inlineLen
          if (length === 7) {
            pos = this.#fill(src, pos, 2)
            if (this.#headLen < 2) return
            length = this.#head[1]!
            guard(length >= 7, 'non minimal medium length')
            if (length === 255) {
              pos = this.#fill(src, pos, 6)
              if (this.#headLen < 6) return
              length = new DataView(this.#head.buffer).getUint32(2)
              guard(length >= 255, 'non minimal large length')
            }
          }
          n = this.#headLen + length
          guard(
            this.#size + n <= this.maxValueBytes,
            'value larger than MaxValueBytes'
          )
          const have = this.#payload.length
          const got = Math.min(length - have, src.length - pos)
          const piece = src.subarray(pos, pos + got)
          pos += got
          if (have === 0 && got === length) {
            // piece borrows src, so only a bytes atom, which keeps it, copies
            v = atom(h.kind, h.kind === 'bytes' ? piece.slice() : piece, h.mark)
          } else {
            this.#payload.append(piece)
            if (have + got < length) return
            v = atom(h.kind, this.#payload.take(), h.mark)
          }
        }
      }
      this.#headLen = 0
      this.#size += n
      guard(this.#size <= this.maxValueBytes, 'value larger than MaxValueBytes')
      const top = this.#open.at(-1)
      if (top === undefined) {
        this.#size = 0
        yield v
      } else top.members.push(v)
    }
  }
}

export function readAll(src: Uint8Array): Value[] {
  return [...new Reader().read(src)]
}

export function readOne(src: Uint8Array): Value {
  for (const v of new Reader().read(src)) return v
  return refuse('failed to read one')
}

// ================
// Writing
// ================

export interface Enc {
  writeNull(mark: boolean): void
  writeAtom(kind: ScalarKind, mark: boolean, payload: Uint8Array): void
  writeOpen(kind: FrameKind, mark: boolean): void
  writeClose(): void
}

export class ByteWriter implements Enc {
  #out = new Bytes()

  get length(): number {
    return this.#out.length
  }

  #header(kind: Kind, mark: boolean, len: number) {
    const out = this.#out
    out.push((TAGS[kind] << 4) | (mark ? MARK_BIT : 0) | Math.min(len, 7))
    if (len >= 255) {
      out.push(0xff)
      for (const shift of [24, 16, 8, 0]) out.push((len >>> shift) & 0xff)
    } else if (len >= 7) out.push(len)
  }

  writeNull(mark: boolean) {
    this.#header('nil', mark, 0)
  }

  writeAtom(kind: ScalarKind, mark: boolean, payload: Uint8Array) {
    guard(payload.length <= MAX_ATOM_PAYLOAD, 'payload too large')
    this.#header(kind, mark, payload.length)
    this.#out.append(payload)
  }

  writeOpen(kind: FrameKind, mark: boolean) {
    this.#header(kind, mark, 0)
  }

  writeClose() {
    this.#out.push(END_BYTE)
  }

  take(): Uint8Array {
    return this.#out.take()
  }
}

export function write(n: Node, enc: Enc): void {
  if (n instanceof Live) return refuse('can only write a fully reified node')
  switch (n.kind) {
    case 'nil':
      return enc.writeNull(n.mark)
    case 'number':
      return enc.writeAtom(n.kind, n.mark, ENC.encode(n.num.toString()))
    case 'text':
    case 'symbol':
      return enc.writeAtom(n.kind, n.mark, ENC.encode(n.str))
    case 'bytes':
      return enc.writeAtom(n.kind, n.mark, n.bytes)
    default:
      enc.writeOpen(n.kind, n.mark)
      for (const m of members(n)) write(m, enc)
      enc.writeClose()
  }
}

// ==================================================
// Sugar
//
// Convenience over the stuff above
// ==================================================

export function ce(n: Node): Uint8Array {
  const out = new ByteWriter()
  write(n, out)
  return out.take()
}

// ================
// Value sugar
// ================

export const marked = (v: Value, mark = true): Value =>
  v.mark === mark ? v : { ...v, mark }

export const unmarked = (v: Value): Value => marked(v, false)

export function num(n: bigint | number | string, mark = false): Value {
  if (typeof n === 'string') {
    guard(isValidInt(n), 'not a canonical number: ' + n)
  } else if (typeof n === 'number') {
    guard(Number.isInteger(n), 'not an integer: ' + n)
  }
  return { kind: 'number', mark, num: BigInt(n) }
}

export function text(s: string, mark = false): Value {
  guard(s.isWellFormed(), 'a lone surrogate has no utf8 form')
  return { kind: 'text', mark, str: s }
}

export function sym(s: string, mark = false): Value {
  guard(s.isWellFormed(), 'a lone surrogate has no utf8 form')
  return { kind: 'symbol', mark, str: s }
}

export const bytes = (b: Uint8Array, mark = false): Value => ({
  kind: 'bytes',
  mark,
  bytes: b,
})

export const list = (items: Iterable<Node> = [], mark = false): Value =>
  frame('list', [...items], mark)

export const rec = (items: Iterable<Node>, mark = false): Value =>
  frame('record', [...items], mark)

// One of each member is kept.
export const set = (items: Iterable<Node> = [], mark = false): Value => ({
  kind: 'set',
  mark,
  items: sortedUnique(items, cmp),
})

// A key given twice holds the entry given last.
export const dict = (entries: Iterable<Entry> = [], mark = false): Value => ({
  kind: 'dict',
  mark,
  entries: sortedUnique(entries, cmpKeys),
})

export function at(v: Value, i: number): Node {
  guard(v.kind === 'list' || v.kind === 'record', 'invalid pos index')
  return v.items[i] ?? refuse('out of bounds')
}

export function setAt(v: Value, i: number, n: Node): Value {
  guard(v.kind === 'list' || v.kind === 'record', 'invalid pos assignment')
  guard(Number.isInteger(i) && i >= 0 && i < v.items.length, 'out of bounds')
  return { ...v, items: v.items.with(i, n) }
}

const keyed =
  (key: Node) =>
  (e: Entry): number =>
    cmp(e[0], key)

const member =
  (n: Node) =>
  (m: Node): number =>
    cmp(m, n)

export function get(v: Value, key: Node): Node | undefined {
  guard(v.kind === 'dict', 'invalid value index')
  const [i, found] = seek(v.entries, keyed(key))
  return found ? v.entries[i]![1] : undefined
}

export function put(v: Value, key: Node, val: Node): Value {
  guard(v.kind === 'dict', 'invalid value assignment')
  const [i, found] = seek(v.entries, keyed(key))
  return { ...v, entries: v.entries.toSpliced(i, found ? 1 : 0, [key, val]) }
}

export function del(v: Value, key: Node): Value {
  guard(v.kind === 'dict', 'invalid delete')
  const [i, found] = seek(v.entries, keyed(key))
  return found ? { ...v, entries: v.entries.toSpliced(i, 1) } : v
}

export function has(v: Value, key: Node): boolean {
  switch (v.kind) {
    case 'list':
    case 'record':
      return v.items.some(m => eq(m, key))
    case 'set':
      return seek(v.items, member(key))[1]
    case 'dict':
      return seek(v.entries, keyed(key))[1]
    default:
      return refuse('not a frame')
  }
}

export function incl(v: Value, n: Node): Value {
  guard(v.kind === 'set', 'invalid incl')
  const [i, found] = seek(v.items, member(n))
  return found ? v : { ...v, items: v.items.toSpliced(i, 0, n) }
}

export function excl(v: Value, n: Node): Value {
  guard(v.kind === 'set', 'invalid excl')
  const [i, found] = seek(v.items, member(n))
  return found ? { ...v, items: v.items.toSpliced(i, 1) } : v
}

// ================
// Node sugar
// ================

// A position counts nodes in preorder from the root at zero. A live is a
// leaf: it holds one position and is never asked what it is.
export function atFlat(root: Node, index: number): Node {
  guard(Number.isInteger(index) && index >= 0, 'invalid flat index')
  let left = index
  const go = (n: Node): Node | undefined => {
    if (left === 0) return n
    if (n instanceof Live) return undefined
    for (const m of members(n)) {
      left--
      const hit = go(m)
      if (hit !== undefined) return hit
    }
    return undefined
  }
  return go(root) ?? refuse('invalid flat index')
}

export function setFlat(root: Node, index: number, value: Node): Node {
  guard(Number.isInteger(index) && index >= 0, 'invalid flat index')
  let left = index
  let placed = false
  const go = (n: Node): Node => {
    if (placed) return n
    if (left === 0) {
      placed = true
      return value
    }
    if (n instanceof Live) return n
    return mapMembers(n, m => {
      if (placed) return m
      left--
      return go(m)
    })
  }
  const out = go(root)
  guard(placed, 'invalid flat index')
  return out
}

export function rewrite(
  n: Node,
  p: (v: Value) => boolean,
  f: (v: Value) => Node
): Node {
  if (n instanceof Live) return n
  if (p(n)) return f(n)
  return mapMembers(n, m => rewrite(m, p, f))
}
