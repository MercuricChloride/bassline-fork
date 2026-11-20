// Shapes: values with holes, and the search for what fills them. A port of
// blnim's queries/rewrite.nim.
//
// A shape is an example value and a set of holes, parts of the example that
// stand for whatever is in their place. Written down it is
//
//   (shape EXAMPLE {HOLE …})  or  (shape EXAMPLE {HOLE …} WILD)
//
// where WILD, in the example, fits anything and binds nothing.
//
// Filling a shape is a little unification search: asked about a value, it
// answers every binding of the holes, {HOLE: VALUE …}, under which the value
// fits the example, one per pull and nothing worked out ahead. A value fits
// where it has the example's kind and mark, and
//
// - a list or record has at least the example's members, the leading ones
//   each fitting the example's in its place;
// - a dict has, for each of the example's entries, an entry whose key and
//   value fit;
// - a set has, for each of the example's members, a member that fits;
// - an atom is the example's.
//
// A key or member with a hole or the wild anywhere in it is tried against
// each of the value's keys or members in turn; one with neither is looked up
// as it is. Two parts of the example may be filled from the same key or
// member: a set example says which members a value has, not how many. A hole
// fits a value of its own mark, and a hole met again fits only what it is
// bound to already, so the bindings found are compatible: a hole bound two
// ways is no filling, never an error. A filling binds every hole, and each is
// answered once. A search can start from bindings already had, and answers
// only those compatible with them.
//
// Each part of the example is a search from bindings to every extension of
// them under which the value's part fits it, and a frame's is its parts' one
// after another: first what the bindings already decide, then what has one
// place to fit, then the part whose candidates are fewest by its known
// leading members, so checks come before anything branches. A list or record
// member is looked for only among those of its kind and mark that begin with
// the members already known, found by bisecting. `inject` goes the other way,
// filling holes from bindings.

import { BTreeSet } from './btree.ts'
import { walk } from './ops.ts'
import { empty, just, pull } from './stream.ts'
import { cmp, eq, isFrame, TAGS, type Factory, type Value } from './types.ts'
import { value } from './values.ts'

export type Shape = {
  /** What a value that fits looks like. */
  example: Value
  /** Parts of the example standing for what is there. */
  holes: Value<'set'>
  /** A part that fits anything and binds nothing. */
  wild?: Value
}

/** A value that is not a shape, or bindings that are not a dict. */
export class ShapeError extends Error {}

export type Bindings = Value<'dict'>

/** Answers, one per pull. */
type Answers<A> = Generator<A, void, unknown>

/** Every extension of the bindings under which a value fits a part. */
export type Fit = (b: Bindings) => Answers<Bindings>

/**
 * Parts of an example that a dialect built on shapes reads its own way: `is`
 * says which, and `fit` fits one, given the fit for any other part. A form is
 * never looked up as written.
 */
export type Forms = {
  is: (part: Value) => boolean
  fit: (part: Value, v: Value, fit: (part: Value, v: Value) => Fit) => Fit
}

/**
 * One part of a frame to fit, the holes it might bind, and, for a part tried
 * against each candidate in turn, how many leading members its candidates
 * are narrowed by under some bindings (none for a part with one place to
 * fit).
 */
type Choice = {
  holes: Value[]
  fit: Fit
  lead?: (b: Bindings) => number
}

const keep: Fit = b => just(b)
const fail: Fit = () => empty()

/** `a`, then `b` from each of the bindings `a` answers. */
const then = (a: Fit, b: Fit): Fit =>
  function* (x) {
    for (const y of a(x)) yield* b(y)
  }

/** How many of the choice's holes the bindings leave unbound. */
const unbound = (c: Choice, b: Bindings) =>
  c.holes.filter(h => !b.has(h)).length

/**
 * Which choice to take first, least first: one with nothing left to bind,
 * which only checks; one with one place to fit, which binds without
 * branching; then the narrowest by its known leading members, binding the
 * most holes at once.
 */
function rank(c: Choice, b: Bindings): [number, number, number] {
  const open = unbound(c, b)
  if (open === 0) return [0, 0, 0]
  if (c.lead === undefined) return [1, 0, 0]
  return [2, -c.lead(b), -open]
}

const before = (x: number[], y: number[]) => {
  for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i]! < y[i]!
  return false
}

/**
 * The choices one after another, the best ranked first each time, so what
 * the bindings already decide is checked before anything branches further.
 * A choice with nothing left to bind can only answer the bindings as they
 * are, so it is asked for one answer.
 */
function choices(cs: Choice[]): Fit {
  return function* (b) {
    if (cs.length === 0) {
      yield b
      return
    }
    let best = 0
    for (let i = 1; i < cs.length; i++) {
      if (before(rank(cs[i]!, b), rank(cs[best]!, b))) best = i
    }
    const c = cs[best]!
    const rest = choices(cs.filter((_, i) => i !== best))
    if (unbound(c, b) === 0) {
      if (pull(c.fit(b)) !== undefined) yield* rest(b)
      return
    }
    for (const b2 of c.fit(b)) yield* rest(b2)
  }
}

/**
 * Where `m` sorts against the lists or records of `kind`, unmarked or marked,
 * that begin with `lead`: before them (< 0), among them (0), or after them
 * (> 0). CE order sorts by kind, then mark, then member by member, and a
 * frame that runs out first sorts after those it begins.
 */
export function against(
  m: Value,
  kind: 'list' | 'record',
  lead: Value[],
  marked: boolean
): number {
  if (m.kind !== kind) return TAGS[m.kind] - TAGS[kind]
  if (m.mark !== marked) return m.mark ? 1 : -1
  const items = (m as Value<'list' | 'record'>).items
  for (let i = 0; i < lead.length; i++) {
    if (i === items.length) return 1
    const c = cmp(items[i]!, lead[i]!)
    if (c !== 0) return c
  }
  return 0
}

/**
 * A set's lists or records (`kind`), unmarked or marked, that begin with the
 * members `lead`, in CE order: one run, found by bisecting.
 */
export function* ledBy(
  set: Value<'set'>,
  kind: 'list' | 'record',
  lead: Value[],
  marked = false
): Answers<Value> {
  for (const m of set.from(m => against(m, kind, lead, marked) >= 0)) {
    if (against(m, kind, lead, marked) > 0) return
    yield m
  }
}

/** Shapes, filled and read and written through the factory `f`. */
export function shapes(f: Factory = value) {
  /** A shape from its example, its holes, and its wild, if it has one. */
  function shape(example: Value, holes: Iterable<Value>, wild?: Value): Shape {
    const s: Shape = { example, holes: f.set(holes) }
    if (wild !== undefined) s.wild = wild
    return s
  }

  /**
   * Reads (shape EXAMPLE {HOLE …}) or (shape EXAMPLE {HOLE …} WILD), and
   * refuses anything else.
   */
  function shapeFrom(v: Value): Shape {
    const ok =
      v.kind === 'record' &&
      !v.mark &&
      eq(v.head, f.sym('shape')) &&
      (v.items.length === 3 || v.items.length === 4) &&
      v.items[2]!.kind === 'set' &&
      !v.items[2]!.mark
    if (!ok) {
      throw new ShapeError(
        'not (shape EXAMPLE {HOLE …}) or (shape EXAMPLE {HOLE …} WILD)'
      )
    }
    const [, example, holes, wild] = v.items as Value[]
    const s: Shape = { example: example!, holes: holes as Value<'set'> }
    if (wild !== undefined) s.wild = wild
    return s
  }

  /** A shape written down. */
  function shapeValue(s: Shape): Value {
    const fields = [f.sym('shape'), s.example, s.holes]
    if (s.wild !== undefined) fields.push(s.wild)
    return f.record(fields)
  }

  function bindingsOf(given: Value): Bindings {
    if (given.kind !== 'dict' || given.mark) {
      throw new ShapeError('bindings are an unmarked dict')
    }
    return given
  }

  /**
   * Every binding of the holes, {HOLE: VALUE …}, under which `v` fits the
   * example, extending the bindings `given`: each once, one per pull,
   * nothing worked out ahead. Refuses `given`, when asked, if it isn't an
   * unmarked dict.
   */
  function fillings(
    s: Shape,
    v: Value,
    given: Value = f.dict()
  ): Answers<Bindings> {
    return unique(s, fitter(s).fit(s.example, v)(bindingsOf(given)))
  }

  /** The bindings that bind every hole, each once. */
  function* unique(s: Shape, found: Answers<Bindings>): Answers<Bindings> {
    const seen = new BTreeSet<Value>(cmp)
    for (const b of found) {
      if (!s.holes.children().every(h => b.has(h)) || seen.has(b)) continue
      seen.add(b)
      yield b
    }
  }

  /**
   * The example with each hole that `bindings` binds filled in, and any
   * other left as it is.
   */
  function inject(s: Shape, bindings: Value): Value {
    const b = bindingsOf(bindings)
    const filled = (part: Value): Value => {
      if (s.holes.has(part) && b.has(part)) return b.get(part)!
      switch (part.kind) {
        case 'list':
          return f.list(part.items.map(filled), part.mark)
        case 'record':
          return f.record(part.items.map(filled), part.mark)
        case 'dict':
          return f.dict(
            part.entries().map(([k, x]) => [filled(k), filled(x)]),
            part.mark
          )
        case 'set':
          return f.set(part.children().map(filled), part.mark)
        default:
          return part
      }
    }
    return filled(s.example)
  }

  /** The fits for one shape, reading `forms` their own way. */
  function fitter(s: Shape, forms?: Forms) {
    const isWild = (part: Value) => s.wild !== undefined && eq(s.wild, part)
    const isHole = (part: Value) => s.holes.has(part)
    const isForm = (part: Value) =>
      forms !== undefined && !isHole(part) && forms.is(part)

    /** Whether `part` has no hole, no wild and no form anywhere in it. */
    const isLiteral = (part: Value) =>
      walk(part).every(p => !isHole(p) && !isWild(p) && !isForm(p))

    /** The holes anywhere in `parts`, each once. */
    function holesIn(...parts: Value[]): Value[] {
      const found = new BTreeSet<Value>(cmp)
      for (const p of parts)
        for (const x of walk(p)) if (isHole(x)) found.add(x)
      return [...found]
    }

    /** `hole` bound to `v`, unless it is bound otherwise already. */
    const bound =
      (hole: Value, v: Value): Fit =>
      b => {
        const was = b.get(hole)
        if (was !== undefined) return eq(was, v) ? just(b) : empty()
        return just(f.dict([...b.entries(), [hole, v]]))
      }

    /**
     * One entry of an example dict against the dict `v`: a literal key
     * looked up, any other tried against each entry in turn.
     */
    function entryChoice(key: Value, item: Value, v: Bindings): Choice {
      if (!isLiteral(key)) {
        return {
          holes: holesIn(key, item),
          lead: () => 0,
          fit: function* (b) {
            for (const [k, x] of v.entries())
              yield* then(fit(key, k), fit(item, x))(b)
          },
        }
      }
      const x = v.get(key)
      if (x === undefined) return { holes: [], fit: fail }
      return { holes: holesIn(item), fit: fit(item, x) }
    }

    /**
     * The leading members of a list or record `m` that fit only what equals
     * them under the bindings `b`: atoms as written, and holes bound
     * already, as far as they run unbroken.
     */
    function settledLead(m: Value, b: Bindings): Value[] {
      if ((m.kind !== 'list' && m.kind !== 'record') || isForm(m) || isHole(m))
        return []
      const lead: Value[] = []
      for (const x of m.items) {
        if (isHole(x)) {
          const w = b.get(x)
          if (w === undefined) break
          lead.push(w)
        } else if (isWild(x) || isFrame(x)) break
        else lead.push(x)
      }
      return lead
    }

    /**
     * The members of the set `v` that might fit `m` under the bindings `b`:
     * the one a bound hole stands for, the lists or records of its kind and
     * mark that begin with its settled lead, or else every member.
     */
    function candidates(
      m: Value,
      v: Value<'set'>,
      b: Bindings
    ): Answers<Value> {
      const w = isHole(m) ? b.get(m) : undefined
      if (w !== undefined) return v.has(w) ? just(w) : empty()
      if (
        (m.kind === 'list' || m.kind === 'record') &&
        !isForm(m) &&
        !isHole(m)
      ) {
        return ledBy(v, m.kind, settledLead(m, b), m.mark)
      }
      return v.children()
    }

    /**
     * One member of an example set against the set `v`: a literal member
     * looked up, any other tried against each member that might fit it.
     */
    function memberChoice(m: Value, v: Value<'set'>): Choice {
      if (isLiteral(m)) return { holes: [], fit: v.has(m) ? keep : fail }
      return {
        holes: holesIn(m),
        lead: b => settledLead(m, b).length,
        fit: function* (b) {
          for (const c of candidates(m, v, b)) yield* fit(m, c)(b)
        },
      }
    }

    /** Every extension of bindings under which `v` fits `part`. */
    function fit(part: Value, v: Value): Fit {
      if (isForm(part)) return forms!.fit(part, v, fit)
      if (isWild(part)) return keep
      if (isHole(part)) {
        if (part.mark === v.mark) return bound(part, v)
        // bound otherwise (from bindings given), it still fits what it is bound to
        const otherwise = shaped(part, v)
        return b => {
          const was = b.get(part)
          if (was === undefined) return otherwise(b)
          return eq(was, v) ? just(b) : empty()
        }
      }
      return shaped(part, v)
    }

    /** Every extension of bindings under which `v` fits `part` as written. */
    function shaped(part: Value, v: Value): Fit {
      if (part.kind !== v.kind || part.mark !== v.mark) return fail
      switch (part.kind) {
        case 'list':
        case 'record': {
          const items = (v as Value<'list' | 'record'>).items
          if (items.length < part.items.length) return fail
          return choices(
            part.items.map((p, i) => ({
              holes: holesIn(p),
              fit: fit(p, items[i]!),
            }))
          )
        }
        case 'dict':
          return choices(
            [...part.entries()].map(([k, x]) =>
              entryChoice(k, x, v as Bindings)
            )
          )
        case 'set':
          return choices(
            [...part.children()].map(m => memberChoice(m, v as Value<'set'>))
          )
        default:
          return eq(part, v) ? keep : fail
      }
    }

    return { fit }
  }

  /**
   * The fit for any part of `s`'s example against a value, reading `forms`
   * their own way: the search from bindings to their extensions that a
   * dialect built on shapes composes its own searches from.
   */
  const fitting = (s: Shape, forms?: Forms) => fitter(s, forms).fit

  return { shape, shapeFrom, shapeValue, fillings, inject, fitting } as const
}
