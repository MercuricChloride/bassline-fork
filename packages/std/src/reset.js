import { failure, is } from '@bassline/core'
import { assertDiff, diff } from './data/diff.js'

const same = (a, b) => Object.is(a, b)

export class ReSet {
  constructor(values = [], { identity = value => value, merge } = {}) {
    if (!is.fn(identity)) throw failure('ReSet: identity must be a function')
    if (!is.undefined(merge) && !is.fn(merge)) {
      throw failure('ReSet: merge must be a function')
    }
    this.identity = identity
    this.merge = merge
    this.current = new Map()
    this.baseline = new Map()
    this.reset(values)
    this.baseline = copyMap(this.current)
  }

  get size() {
    return this.current.size
  }

  add(value) {
    this.setValue(this.current, value)
    return this
  }

  delete(value) {
    return this.current.delete(this.key(value))
  }

  has(value) {
    return this.current.has(this.key(value))
  }

  get(value) {
    return this.current.get(this.key(value))
  }

  clear() {
    this.current.clear()
    return this
  }

  reset(values, fn) {
    if (!is.array(values)) throw failure('ReSet.reset: values must be an array')
    if (!is.undefined(fn) && !is.fn(fn)) {
      throw failure('ReSet.reset: fn must be a function')
    }
    const previous = this.snapshot()
    const next = fn ? fn(previous, values) : values
    if (!is.array(next)) {
      throw failure('ReSet.reset: final values must be an array')
    }
    this.current = this.mapFrom(next)
    return this
  }

  apply(aDiff) {
    assertDiff(aDiff)
    const next = copyMap(this.current)
    for (const value of aDiff.get('add')) this.setValue(next, value)
    for (const value of aDiff.get('remove')) next.delete(this.key(value))
    this.current = next
    return this
  }

  checkpoint() {
    const values = this.snapshot()
    return fn => this.reset(values, fn)
  }

  snapshot() {
    return Array.from(this.current.values())
  }

  changes(aMsg) {
    return diff(...diffMaps(this.baseline, this.current), aMsg)
  }

  drain(aMsg) {
    const changes = this.changes(aMsg)
    this.baseline = copyMap(this.current)
    return changes
  }

  clone() {
    return this.like(this.snapshot())
  }

  union(values) {
    return this.like([...this, ...toArray(values, 'ReSet.union')])
  }

  intersection(values) {
    const other = this.mapFrom(toArray(values, 'ReSet.intersection'))
    return this.like(
      this.snapshot().filter(value => other.has(this.key(value)))
    )
  }

  difference(values) {
    const other = this.mapFrom(toArray(values, 'ReSet.difference'))
    return this.like(
      this.snapshot().filter(value => !other.has(this.key(value)))
    )
  }

  symmetricDifference(values) {
    const other = this.mapFrom(toArray(values, 'ReSet.symmetricDifference'))
    const next = this.snapshot().filter(value => !other.has(this.key(value)))
    for (const [key, value] of other) {
      if (!this.current.has(key)) next.push(value)
    }
    return this.like(next)
  }

  equals(values) {
    return this.isSubsetOf(values) && this.isSupersetOf(values)
  }

  isSubsetOf(values) {
    const other = this.mapFrom(toArray(values, 'ReSet.isSubsetOf'))
    for (const key of this.current.keys()) {
      if (!other.has(key)) return false
    }
    return true
  }

  isSupersetOf(values) {
    const other = this.mapFrom(toArray(values, 'ReSet.isSupersetOf'))
    for (const key of other.keys()) {
      if (!this.current.has(key)) return false
    }
    return true
  }

  isDisjointFrom(values) {
    const other = this.mapFrom(toArray(values, 'ReSet.isDisjointFrom'))
    for (const key of other.keys()) {
      if (this.current.has(key)) return false
    }
    return true
  }

  map(fn, options) {
    if (!is.fn(fn)) throw failure('ReSet.map: fn must be a function')
    return this.like(
      this.snapshot().map(value => fn(value, this.key(value), this)),
      options
    )
  }

  filter(fn) {
    if (!is.fn(fn)) throw failure('ReSet.filter: fn must be a function')
    return this.like(
      this.snapshot().filter(value => fn(value, this.key(value), this))
    )
  }

  // Note to reader!
  // We use ...args rather than a default argument value to
  // be able to distinguish between reduce(fn) and reduce(fn, undefined)
  // it's a bit subtle but the distinction is
  // arity 1: fold starting from (vals[0], vals[1])
  // arity 2: fold starting from (undefined, vals[0])
  reduce(fn, ...args) {
    if (!is.fn(fn)) throw failure('ReSet.reduce: fn must be a function')
    const values = this.snapshot()
    if (values.length === 0 && args.length === 0) {
      throw failure('ReSet.reduce: empty set with no initial value')
    }
    let idx = 0
    let acc
    if (args.length > 0) {
      acc = args[0]
    } else {
      acc = values[0]
      idx = 1
    }
    for (; idx < values.length; idx++) {
      const value = values[idx]
      acc = fn(acc, value, this.key(value), this)
    }
    return acc
  }

  forEach(fn) {
    if (!is.fn(fn)) throw failure('ReSet.forEach: fn must be a function')
    for (const value of this) fn(value, this.key(value), this)
  }

  some(fn) {
    if (!is.fn(fn)) throw failure('ReSet.some: fn must be a function')
    for (const value of this) {
      if (fn(value, this.key(value), this)) return true
    }
    return false
  }

  every(fn) {
    if (!is.fn(fn)) throw failure('ReSet.every: fn must be a function')
    for (const value of this) {
      if (!fn(value, this.key(value), this)) return false
    }
    return true
  }

  find(fn) {
    if (!is.fn(fn)) throw failure('ReSet.find: fn must be a function')
    for (const value of this) {
      if (fn(value, this.key(value), this)) return value
    }
  }

  values() {
    return this.current.values()
  }

  keys() {
    return this.values()
  }

  entries() {
    return Array.from(this.current.values(), value => [value, value]).values()
  }

  [Symbol.iterator]() {
    return this.values()
  }

  key(value) {
    return this.identity(value)
  }

  mapFrom(values) {
    const map = new Map()
    for (const value of values) this.setValue(map, value)
    return map
  }

  like(values, options = {}) {
    return new ReSet(values, this.options(options))
  }

  options(options = {}) {
    return {
      identity: options.identity ?? this.identity,
      merge: Object.hasOwn(options, 'merge') ? options.merge : this.merge,
    }
  }

  setValue(map, value) {
    assertValue(value)
    const key = this.key(value)
    if (!map.has(key)) {
      map.set(key, value)
      return value
    }
    const current = map.get(key)
    if (same(current, value)) return current
    if (!this.merge) {
      throw failure('ReSet: duplicate identity without merge')
    }
    const merged = this.merge(current, value, key)
    assertValue(merged)
    if (!same(this.key(merged), key)) {
      throw failure('ReSet: merge changed identity')
    }
    map.set(key, merged)
    return merged
  }
}

function copyMap(map) {
  return new Map(map)
}

function assertValue(value) {
  if (is.undefined(value)) throw failure('ReSet: value cannot be undefined')
}

function toArray(values, name) {
  if (is.array(values)) return values
  if (!values?.[Symbol.iterator]) {
    throw failure(`${name}: values must be iterable`)
  }
  return Array.from(values)
}

function diffMaps(before, after) {
  const add = []
  const remove = []
  for (const [key, value] of before) {
    if (!after.has(key)) {
      remove.push(value)
      continue
    }
    const next = after.get(key)
    if (!same(value, next)) {
      remove.push(value)
      add.push(next)
    }
  }
  for (const [key, value] of after) {
    if (!before.has(key)) add.push(value)
  }
  return [add, remove]
}
