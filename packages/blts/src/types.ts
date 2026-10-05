import type { BTree, BTreeSet } from './btree.ts'

export const TAGS = {
  nil: 1,
  number: 2,
  text: 3,
  symbol: 4,
  bytes: 5,
  list: 6,
  record: 7,
  dict: 8,
  set: 9,
} as const

const KIND_OF_TAG = new Map(
  Object.entries(TAGS).map(([k, t]) => [t as number, k as ValueKind])
)

/** The kind a tag names, or undefined for a tag that names none. */
export function tagToKind(tag: number): ValueKind | undefined {
  return KIND_OF_TAG.get(tag)
}

export type AtomKind = 'nil' | 'number' | 'text' | 'symbol' | 'bytes'
export type FrameKind = 'list' | 'record' | 'dict' | 'set'
export type ValueKind = AtomKind | FrameKind
export type Value<K extends ValueKind = ValueKind> = Values[K]

type Values = {
  nil: INil
  number: INumber
  text: IText
  symbol: ISymbol
  bytes: IBytes
  list: IList
  record: IRecord
  dict: IDict
  set: ISet
}

/**
 * One constructor per kind. The decoder and the text reader take one, so
 * neither is tied to a value implementation; whatever they need of a value
 * comes through these interfaces. A dict or set puts what it is given in
 * canonical order and keeps one of each.
 */
export type Factory = {
  nil: (mark?: boolean) => INil
  number: (n: number | bigint, mark?: boolean) => INumber
  text: (s: string, mark?: boolean) => IText
  sym: (s: string, mark?: boolean) => ISymbol
  bytes: (b: Uint8Array, mark?: boolean) => IBytes
  list: (items?: Iterable<Value>, mark?: boolean) => IList
  record: (items: Iterable<Value>, mark?: boolean) => IRecord
  dict: (entries?: Iterable<[Value, Value]>, mark?: boolean) => IDict
  set: (items?: Iterable<Value>, mark?: boolean) => ISet
}

/**
 * What every value has. A value is not changed once it is built: nothing here
 * hands out a way to change one, and a payload or array it shares is not to be
 * mutated either.
 */
interface IValue<K extends ValueKind> {
  readonly kind: K
  readonly mark: boolean
  /**
   * An atom's payload length in CE bytes (UTF-8 for text and symbols, the
   * decimal spelling for integers, 0 for nil); a frame's count of members,
   * a dict's of entries.
   */
  get length(): number
}

interface INil extends IValue<'nil'> {
  readonly payload: null
}

/**
 * An integer, held whole and in one host form: a number when it is a safe
 * integer, a bigint otherwise, so `payload === 5` means what it says.
 */
interface INumber extends IValue<'number'> {
  readonly payload: number | bigint
}

/** Text held as well-formed UTF-16, so it has a UTF-8 form: no lone surrogates. */
interface IText extends IValue<'text'> {
  readonly payload: string
}

/** As text: well-formed, no lone surrogates. */
interface ISymbol extends IValue<'symbol'> {
  readonly payload: string
}

interface IBytes extends IValue<'bytes'> {
  readonly payload: Uint8Array
}

interface IList extends IValue<'list'> {
  readonly items: readonly Value[]
  /** The items, in order. */
  children(): Generator<Value>
}

/** A record always has a head. */
interface IRecord extends IValue<'record'> {
  readonly items: readonly Value[]
  get head(): Value
  /** The items after the head. */
  get fields(): Value[]
  /** The items, head first. */
  children(): Generator<Value>
}

/**
 * Keys are unique and held in canonical order, the order of their CE bytes;
 * the encoder and `cmp` read them in the order given here.
 */
interface IDict extends IValue<'dict'> {
  /** Key, value, key, value, by key in canonical order. */
  children(): Generator<Value>
  /** Entries by key in canonical order. */
  entries(): Generator<[Value, Value]>
  has(key: Value): boolean
  get(key: Value): Value | undefined
  /**
   * The entries as a tree of their own, to add to and build a new dict from;
   * this dict is untouched.
   */
  tree(): BTree<Value, Value>
}

/** Members are unique and held in canonical order, the order of their CE bytes. */
interface ISet extends IValue<'set'> {
  /** Members in canonical order. */
  children(): Generator<Value>
  has(member: Value): boolean
  /**
   * The members as a tree of their own, to add to and build a new set from;
   * this set is untouched.
   */
  tree(): BTreeSet<Value>
}

// ================
// Comparators
// ================

export type Atom = Value<AtomKind>
export type Frame = Value<FrameKind>

export const isAtom = (v: Value): v is Atom =>
  v.kind === 'nil' ||
  v.kind === 'number' ||
  v.kind === 'text' ||
  v.kind === 'symbol' ||
  v.kind === 'bytes'

export const isFrame = (v: Value): v is Frame =>
  v.kind === 'list' ||
  v.kind === 'record' ||
  v.kind === 'dict' ||
  v.kind === 'set'

function* lockstep<A>(a: Generator<A>, b: Generator<A>) {
  while (true) {
    const x = a.next()
    const y = b.next()

    if (x.done || y.done) return
    yield [x.value, y.value] as const
  }
}

const compare = {
  values(a: Value, b: Value): number {
    return compare.kind(a, b) || compare.mark(a, b) || compare.content(a, b)
  },
  mark(a: Value, b: Value) {
    if (a.mark == b.mark) return 0
    else return a.mark ? 1 : -1
  },
  kind(a: Value, b: Value) {
    if (a.kind == b.kind) return 0
    else return TAGS[a.kind] > TAGS[b.kind] ? 1 : -1
  },
  content(a: Value, b: Value) {
    switch (a.kind) {
      case 'nil':
        return 0
      case 'number':
        return compare.numbers(a.payload, (b as INumber).payload)
      case 'symbol':
      case 'text':
        return compare.text(a.payload, (b as ISymbol).payload)
      case 'bytes':
        return compare.bytes(a.payload, (b as IBytes).payload)
      case 'list':
      case 'record':
      case 'set': {
        let c = compare.children(a.children(), (b as IList).children())
        if (c !== 0) return c
        else if (a.length !== b.length) {
          // this looks backwards, but the END byte is > all other value bytes
          return a.length > b.length ? -1 : 1
        } else return 0
      }
      case 'dict': {
        let c = compare.entries(a.entries(), (b as IDict).entries())
        if (c !== 0) return c
        else if (a.length !== b.length) {
          // this looks backwards, but the END byte is > all other values
          return a.length > b.length ? -1 : 1
        } else return 0
      }
    }
  },
  children(a: Generator<Value>, b: Generator<Value>) {
    for (const [x, y] of lockstep(a, b)) {
      let c = compare.values(x, y)
      if (c !== 0) return c
    }
    return 0
  },
  entries(a: Generator<[Value, Value]>, b: Generator<[Value, Value]>) {
    for (const [x, y] of lockstep(a, b)) {
      let c = compare.values(x[0], y[0])
      if (c !== 0) return c
      c = compare.values(x[1], y[1])
      if (c !== 0) return c
    }
    return 0
  },
  /** Shortlex on the UTF-8 bytes, which within a length is code point order. */
  text(a: string, b: string) {
    if (a === b) return 0
    const n = utf8Length(a)
    const m = utf8Length(b)
    if (n !== m) return n > m ? 1 : -1
    for (let i = 0; i < a.length; ) {
      const x = a.codePointAt(i)!
      const y = b.codePointAt(i)!
      if (x !== y) return x > y ? 1 : -1
      i += x > 0xffff ? 2 : 1
    }
    return 0
  },
  bytes(a: Uint8Array, b: Uint8Array) {
    if (a.length !== b.length) {
      return a.length > b.length ? 1 : -1
    }
    if (a == b) {
      return 0
    }
    let n = Math.min(a.length, b.length)
    for (let i = 0; i < n; i++) {
      let x = a[i]!
      let y = b[i]!
      if (x == y) continue
      else if (x > y) return 1
      else return -1
    }
    return 0
  },
  numbers(a: number | bigint, b: number | bigint): number {
    return compare.text(spelling(a), spelling(b))
  },
} as const

export function cmp(a: Value, b: Value) {
  return compare.values(a, b)
}

export function eq(a: Value, b: Value) {
  return cmp(a, b) == 0
}

export function cmpEntries(a: [Value, Value], b: [Value, Value]) {
  return cmp(a[0], b[0]) || cmp(a[1], b[1])
}

/**
 * An integer's canonical decimal spelling. A double past 2^53 is still an
 * exact integer, but `toString` would spell it with an exponent.
 */
export function spelling(n: number | bigint) {
  return typeof n === 'number' && !Number.isSafeInteger(n)
    ? BigInt(n).toString()
    : n.toString()
}

/** The length of a well-formed string's UTF-8 encoding. */
export function utf8Length(s: string) {
  let n = 0
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c < 0xdc00) {
      n += 4 // a surrogate pair, one code point
      i++
    } else n += 3
  }
  return n
}
