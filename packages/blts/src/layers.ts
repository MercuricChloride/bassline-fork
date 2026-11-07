// Layers: what a value carries beside itself. A port of tinybl's layers
// (packages/tinybl/src/tinybl/values.nim).
//
// A layer is a runtime domain object, such as a task as a board knows it, a
// parsed shape or a place, living on one node of a value. It is never part of
// the value's bytes, its equality or its encoding, and two equal values on two
// nodes may carry different layers. A layer kind is a class extending Layer,
// and inheritance between kinds is class inheritance. Kinds are told apart
// by the class itself, never by its name, so two modules each with a `Cell`
// never meet.
//
// A reader reads a layer from a value alone; a binder says whether a layer
// made apart from a value goes on it. Each runs in order of priority, the
// lowest number first, and those of one priority in the order they were
// added. A reader may name a head, a dialect word its author picks: it is
// then asked only of a record led by that symbol, or of an object (a marked
// set) with a member record led by it.
//
// attach keeps the first layer a kind's readers read, as a convenience for
// the one reading a program wants; a value no reader reads as that kind is
// remembered too, until another reader is added. readings yields what every
// reader reads, attaching nothing: which to take is the caller's choice.
//
// Equal values are never one node, but a frame's members are shared by
// reference: build a value from another's members and a layer on a member
// shows from both. Before putting state on a node you didn't build, take
// fresh(v), the same value on a node of its own.

import { isObject } from './object.ts'
import type { Value } from './types.ts'
import { value } from './values.ts'

export const HIGH = 25
export const MED = 50
export const LOW = 100

/** What a value carries beside itself. Extend it to make a layer kind. */
export abstract class Layer {
  /** This layer written as a value, for kinds that have one; a runtime-only kind has none. */
  mold?(): Value | undefined
}

/** A layer kind: a class extending Layer. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type Kind<L extends Layer = Layer> = abstract new (...args: any[]) => L

export type ReadFn<L extends Layer> = (v: Value) => L | undefined
export type BindFn<L extends Layer> = (layer: L, v: Value) => boolean
type Def<F> = {
  fn: F
  priority: number
  n: number
  head?: string | undefined
  kind: Kind
}

type Table = {
  readers: Def<ReadFn<Layer>>[]
  binders: Def<BindFn<Layer>>[]
  private: boolean
}

const tables = new Map<Kind, Table>()
const carriedBy = new WeakMap<Value, Layer[]>()
// kinds no reader read a node as, with how many definitions there were then
const readNone = new WeakMap<Value, Map<Kind, number>>()
let added = 0

function tableOf(k: Kind): Table {
  let t = tables.get(k)
  if (!t) {
    t = { readers: [], binders: [], private: false }
    tables.set(k, t)
  }
  return t
}

const byRank = (
  a: { priority: number; n: number },
  b: { priority: number; n: number }
) => a.priority - b.priority || a.n - b.n

/** The kind a kind inherits from, or undefined at Layer. */
function parentOf(k: Kind): Kind | undefined {
  const p = Object.getPrototypeOf(k) as Kind | null
  return p && p !== Layer && p.prototype instanceof Layer ? p : undefined
}
const isKindOf = (k: Kind, of: Kind) => k === of || k.prototype instanceof of

/**
 * Settle how a kind is shown: a private kind never turns up in readings or
 * readAll unless asked for by kind, so a module can keep its layers to itself.
 */
export function declare(k: Kind, o: { private?: boolean }) {
  tableOf(k).private = !!o.private
}

/** Add a reader for kind `k`: a layer read from a value alone, or undefined when it reads none. */
export function reader<L extends Layer>(
  k: Kind<L>,
  read: ReadFn<L>,
  o: { priority?: number; head?: string } = {}
) {
  const t = tableOf(k)
  t.readers.push({
    fn: read as ReadFn<Layer>,
    priority: o.priority ?? MED,
    n: added++,
    head: o.head,
    kind: k,
  })
  t.readers.sort(byRank)
}

/** Add a binder for kind `k`: whether a layer of it made apart from a value goes on that value. */
export function binder<L extends Layer>(
  k: Kind<L>,
  bind: BindFn<L>,
  o: { priority?: number } = {}
) {
  const t = tableOf(k)
  t.binders.push({
    fn: bind as BindFn<Layer>,
    priority: o.priority ?? MED,
    n: added++,
    kind: k,
  })
  t.binders.sort(byRank)
}

/**
 * The heads a value answers to: a record's leading symbol, or, since an
 * object (a marked set) has no head of its own, the leading symbols of its
 * member records, the questions it answers: a message with a (task …) field
 * answers to task. Any other value answers to none.
 */
export function headsOf(v: Value): Set<string> {
  const out = new Set<string>()
  if (v.kind === 'record') {
    const h = v.items[0]
    if (h?.kind === 'symbol') out.add(h.payload)
  } else if (isObject(v)) {
    for (const m of v.children()) {
      if (m.kind === 'record' && m.items[0]?.kind === 'symbol')
        out.add(m.items[0].payload)
    }
  }
  return out
}

const fits = (d: { head?: string | undefined }, heads: Set<string>) =>
  d.head === undefined || heads.has(d.head)

/** What `v` carries, in the order it was put on. */
export function layersOf(v: Value): readonly Layer[] {
  return carriedBy.get(v) ?? []
}

/** The layer of kind `k` (or a kind inheriting from it) that `v` carries, reading nothing. */
export function carried<L extends Layer>(v: Value, k: Kind<L>): L | undefined {
  return layersOf(v).find(l => l instanceof k) as L | undefined
}

function put(v: Value, l: Layer) {
  const ls = carriedBy.get(v)
  if (ls) ls.push(l)
  else carriedBy.set(v, [l])
}

/** Take that very layer off `v`. */
export function remove(v: Value, layer: Layer): boolean {
  const ls = carriedBy.get(v)
  const i = ls ? ls.indexOf(layer) : -1
  if (i < 0) return false
  ls!.splice(i, 1)
  return true
}

/** The readers that may read `v` as kind `k`: its own first, then those of kinds inheriting from it. */
function readersFor(k: Kind, v: Value): Def<ReadFn<Layer>>[] {
  const heads = headsOf(v)
  const own = (tables.get(k)?.readers ?? []).filter(d => fits(d, heads))
  const below: Def<ReadFn<Layer>>[] = []
  for (const [kk, t] of tables)
    if (kk !== k && isKindOf(kk, k))
      below.push(...t.readers.filter(d => fits(d, heads)))
  return [...own, ...below.sort(byRank)]
}

/**
 * The layer of kind `k` that `v` carries; when it carries none, the first one
 * a reader reads, put on `v` and kept.
 */
export function attach<L extends Layer>(v: Value, k: Kind<L>): L | undefined {
  const had = carried(v, k)
  if (had) return had
  if (readNone.get(v)?.get(k) === added) return undefined
  for (const d of readersFor(k, v)) {
    const l = d.fn(v)
    if (l) {
      put(v, l)
      return l as L
    }
  }
  let none = readNone.get(v)
  if (!none) readNone.set(v, (none = new Map()))
  none.set(k, added)
  return undefined
}

/**
 * Whether `v` carries `layer`, put on it when the first of its binders to
 * take `v` does: its own kind's binders before those it inherits.
 */
export function attachLayer(v: Value, layer: Layer): boolean {
  if (layersOf(v).includes(layer)) return true
  for (
    let k: Kind | undefined = layer.constructor as Kind;
    k;
    k = parentOf(k)
  ) {
    for (const d of tables.get(k)?.binders ?? []) {
      if (d.fn(layer, v)) {
        put(v, layer)
        return true
      }
    }
  }
  return false
}

/**
 * What every reader reads `v` as, in priority order, attaching nothing. With
 * `kinds`, only readers of those kinds (and kinds inheriting from them),
 * private ones included; without, every kind that isn't private.
 */
export function* readings(v: Value, kinds?: Kind[]): Generator<Layer> {
  const heads = headsOf(v)
  const defs: Def<ReadFn<Layer>>[] = []
  for (const [k, t] of tables) {
    const asked = kinds ? kinds.some(x => isKindOf(k, x)) : !t.private
    if (asked) defs.push(...t.readers.filter(d => fits(d, heads)))
  }
  for (const d of defs.sort(byRank)) {
    const l = d.fn(v)
    if (l) yield l
  }
}

/**
 * Attach every kind that reads `v` (private ones only when named), one layer
 * per kind, and answer all `v` carries.
 */
export function readAll(v: Value, kinds?: Kind[]): readonly Layer[] {
  const heads = headsOf(v)
  const defs: Def<ReadFn<Layer>>[] = []
  for (const [k, t] of tables) {
    const asked = kinds ? kinds.some(x => isKindOf(k, x)) : !t.private
    if (asked) defs.push(...t.readers.filter(d => fits(d, heads)))
  }
  for (const d of defs.sort(byRank)) {
    if (layersOf(v).some(l => l.constructor === d.kind)) continue
    const l = d.fn(v)
    if (l) put(v, l)
  }
  return layersOf(v)
}

/** Attach kind `k` to `v` and to every value inside it. */
export function attachAll(v: Value, k: Kind) {
  attach(v, k)
  if (
    v.kind === 'list' ||
    v.kind === 'record' ||
    v.kind === 'dict' ||
    v.kind === 'set'
  ) {
    for (const c of v.children()) attachAll(c, k)
  }
}

/** The molds of the layers `v` carries that have one: what it is, as values. */
export function moldsOf(v: Value): Value<'set'> {
  const out: Value[] = []
  for (const l of layersOf(v)) {
    const m = l.mold?.()
    if (m) out.push(m)
  }
  return value.set(out)
}

/** The same value on a new node, carrying no layers; its members are shared. */
export function fresh<V extends Value>(v: V): V {
  switch (v.kind) {
    case 'nil':
      return value.nil(v.mark) as V
    case 'number':
      return value.number(v.payload, v.mark) as V
    case 'text':
      return value.text(v.payload, v.mark) as V
    case 'symbol':
      return value.sym(v.payload, v.mark) as V
    case 'bytes':
      return value.bytes(v.payload, v.mark) as V
    case 'list':
      return value.list(v.items, v.mark) as V
    case 'record':
      return value.record(v.items, v.mark) as V
    case 'dict':
      return value.dict(v.entries(), v.mark) as V
    case 'set':
      return value.set(v.children(), v.mark) as V
  }
  return v
}
