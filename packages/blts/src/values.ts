import { cmp, spelling, utf8Length } from './types.ts'
import type { Value, Factory } from './types.ts'
import { BTree, BTreeSet } from './btree.ts'

class BNil implements Value<'nil'> {
  readonly payload = null
  readonly kind = 'nil'

  readonly mark: boolean
  constructor(mark: boolean = false) {
    this.mark = mark
  }

  get length(): number {
    return 0
  }
}

class BNum implements Value<'number'> {
  readonly payload: number | bigint
  readonly mark: boolean
  constructor(payload: number | bigint, mark: boolean = false) {
    this.payload = payload
    this.mark = mark
    if (typeof payload == 'number' && !Number.isInteger(payload)) {
      throw new TypeError('not an integer: ' + payload)
    }
  }
  readonly kind = 'number'
  get length(): number {
    return spelling(this.payload).length
  }
}

class BText implements Value<'text'> {
  readonly payload: string
  readonly mark: boolean
  constructor(payload: string, mark: boolean = false) {
    this.payload = payload
    this.mark = mark
    if (!payload.isWellFormed()) {
      throw new TypeError('a lone surrogate has no UTF-8 form')
    }
  }
  readonly kind = 'text'
  get length(): number {
    return utf8Length(this.payload)
  }
}

class BSym implements Value<'symbol'> {
  readonly payload: string
  readonly mark: boolean
  constructor(payload: string, mark: boolean = false) {
    this.payload = payload
    this.mark = mark
    if (!payload.isWellFormed()) {
      throw new TypeError('a lone surrogate has no UTF-8 form')
    }
  }
  readonly kind = 'symbol'
  get length(): number {
    return utf8Length(this.payload)
  }
}

class BBytes implements Value<'bytes'> {
  readonly payload: Uint8Array
  readonly mark: boolean
  constructor(payload: Uint8Array, mark: boolean = false) {
    this.payload = payload
    this.mark = mark
  }
  readonly kind = 'bytes'
  get length(): number {
    return this.payload.length
  }
}

class BList implements Value<'list'> {
  readonly items: readonly Value[]
  readonly mark: boolean
  constructor(items: Iterable<Value>, mark: boolean = false) {
    this.mark = mark
    this.items = Array.from(items)
  }
  readonly kind = 'list'
  get length(): number {
    return this.items.length
  }
  *children(): Generator<Value> {
    yield* this.items
  }
}

class BRecord implements Value<'record'> {
  readonly items: readonly Value[]
  readonly mark: boolean
  constructor(items: Iterable<Value>, mark: boolean = false) {
    this.mark = mark
    this.items = Array.from(items)
    if (this.items.length == 0) {
      throw new TypeError('records cannot be empty')
    }
  }
  readonly kind = 'record'
  get head(): Value {
    return this.items[0]!
  }
  get fields(): Value[] {
    return this.items.slice(1)
  }
  get length(): number {
    return this.items.length
  }
  *children(): Generator<Value> {
    yield this.head
    yield* this.fields
  }
}

class BDict implements Value<'dict'> {
  readonly items: BTree<Value, Value>
  readonly mark: boolean
  constructor(entries: Iterable<[Value, Value]>, mark: boolean = false) {
    this.mark = mark
    this.items = new BTree(cmp, entries)
  }
  readonly kind = 'dict'
  get length(): number {
    return this.items.size
  }
  *entries() {
    yield* this.items
  }
  *children(): Generator<Value> {
    for (const [k, v] of this.items) {
      yield k
      yield v
    }
  }
  has(k: Value) {
    return this.items.has(k)
  }
  get(k: Value): Value | undefined {
    return this.items.get(k)
  }
}

class BSet implements Value<'set'> {
  readonly items: BTreeSet<Value>
  readonly mark: boolean
  constructor(items: Iterable<Value>, mark: boolean = false) {
    this.mark = mark
    this.items = new BTreeSet(cmp, items)
  }
  readonly kind = 'set'
  get length(): number {
    return this.items.size
  }
  *children(): Generator<Value> {
    yield* this.items
  }
  has(k: Value) {
    return this.items.has(k)
  }
}

export const value: Factory = {
  nil: (mark = false) => new BNil(mark),
  number: (n, mark = false) => new BNum(n, mark),
  text: (s, mark = false) => new BText(s, mark),
  sym: (s, mark = false) => new BSym(s, mark),
  bytes: (b, mark = false) => new BBytes(b, mark),
  list: (items = [], mark = false) => new BList(items, mark),
  record: (items = [], mark = false) => new BRecord(items, mark),
  dict: (entries = [], mark = false) => new BDict(entries, mark),
  set: (items = [], mark = false) => new BSet(items, mark),
}
