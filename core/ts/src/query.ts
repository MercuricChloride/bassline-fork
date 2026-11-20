// Finds: queries written down as search spaces, and the searches they stand
// for.
//
// A find is an object, one more kind of search space:
//
//   !{!(kind search-space) !(kind find) (identity ID)
//     (of SUBJECT) …       what it asks of
//     (hole H) …           parts of its clauses that stand for what is there
//     (asked H) …          holes bound to whatever the find is asked
//     (where CLAUSE) …     what must be found, each clause a shape's example
//     (gives W) …}         each answer: W, its holes filled in
//
// A subject is a search space (held, composite, or another find), an object,
// whose records are what it answers, or names of one, found when the find is
// asked through a search the asker hands in, which may answer a search
// running here as readily as a value. Several subjects take turns.
//
// Each clause is fitted against a subject's records, as a shape is: holes
// bound under which a record fits it. A clause whose question (its record's
// head) is settled by the bindings so far asks for that question's records
// alone, found by bisecting; any other looks at every record a subject can
// say it holds, which a search running here can't. Clauses are a set: which
// goes next is chosen as the bindings grow, those that only check first,
// then those whose question is settled, then the rest. Each clause is a
// search from bindings to their extensions, and the find feeds the bindings
// through them. A record (Q R A) of a ranked space fits a clause (Q A), its
// rank passed over, and a clause of three fields as it is; a hole or form
// that takes the whole record takes it as held, rank and all.
//
// A clause that only checks, holding no hole the bindings leave open, is asked
// for one answer, or under `why` one for each part that answers it. What each binding leads to takes turns with the rest, so a
// subject that never runs out starves none of them. A subject is read as
// `fromValue` reads a space, refusing what it refuses unless the asker passes
// over refusals, and a name or find met again on its own way round is passed
// over.
//
// A find answers each binding found once, written as each of its gives whose
// holes the binding binds, or, giving nothing, as the bindings themselves.
// A gives may hold a find, its own holes left alone: it asks of the outer
// find's subjects, as written, when it says nothing to ask of, and each of
// its names goes with the bindings it was filled from, so each filling is a
// thing of its own. An answer can carry a further question to ask when
// wanted. Further kinds add to it: `distinct` answers each answer once,
// `count` answers how many it has found so far as each is found, and `why`
// answers (why ANSWER {PART …}), the parts whose records answered, once for
// each set of parts that answers it.
//
// Within a clause a few marked records are read as forms, never looked up as
// written: !(within P) fits a value with something fitting P anywhere in it,
// itself included; !(any P …) fits what fits any of them; !(all P …) what
// fits every one; !(as H P) what fits P, binding the hole H to it whatever
// its mark, and !(as H) anything, so bound; and !(quote V) is V as written.

import { BTreeSet } from './btree.ts'
import { answers, isObject, objects } from './object.ts'
import { walk } from './ops.ts'
import { Search, SearchError, searches } from './search.ts'
import {
  against,
  ledBy,
  shapes,
  type Bindings,
  type Fit,
  type Forms,
} from './shape.ts'
import {
  alt,
  altFrom,
  empty,
  just,
  merge,
  pull,
  type Stream,
  stream,
} from './stream.ts'
import { cmp, eq, TAGS, type Factory, type Value } from './types.ts'
import { value } from './values.ts'

/** A find, read. */
export type Find = {
  /** What it asks of. */
  of: Value[]
  holes: Value<'set'>
  /** Holes bound to what the find is asked. */
  asked: Value[]
  wheres: Value[]
  gives: Value[]
  distinct: boolean
  count: boolean
  why: boolean
}

/** Which part answered a clause. */
export type Because = { clause: Value; from: Value }

/** One answer of a find, the bindings it was written from, and which part answered each clause. */
export type Row = { answer: Value; bindings: Bindings; why: Because[] }

/** What names are found as: spaces and objects written down, or searches running here. */
export type Found = Value | Search<Value, Value>

/** A search of what names stand for, or a function that asks like one. */
export type Resolve = Search<Value, Found> | ((names: Value) => Iterable<Found>)

/** A record a subject holds, the part holding it, and whether it is ranked, (Q R A). */
type Hit = { record: Value<'record'>; from: Value; ranked: boolean }

/**
 * What a clause asks a subject for: its records, marked or not, whose head is
 * `exact`, or else a list or record of `led.kind` and `led.mark` beginning
 * with `led.lead`. `value`, when there is one, is the one head a search
 * running here can be asked about; what it answers fits, and is all it can say.
 */
type Question = {
  marked: boolean
  exact?: Value
  led?: { kind: 'list' | 'record'; lead: Value[]; mark: boolean }
  value?: Value
}

/** Something a find asks of. */
type Subject = {
  /** Its records answering any of `qs`: in rank order when it is ranked, otherwise taking turns. */
  headed: (qs: Question[]) => Iterable<Hit>
  /** Every record it can say it holds. */
  all: () => Iterable<Hit>
}

/** A set's records, marked or not, whose head is led as `led` says, found by bisecting. */
function* ledHeads(
  set: Value<'set'>,
  marked: boolean,
  led: NonNullable<Question['led']>
) {
  const pos = (m: Value) => {
    if (m.kind !== 'record') return TAGS[m.kind] - TAGS.record
    if (m.mark !== marked) return m.mark ? 1 : -1
    return against(m.items[0]!, led.kind, led.lead, led.mark)
  }
  for (const m of set.from(m => pos(m) >= 0)) {
    if (pos(m) > 0) return
    yield m as Value<'record'>
  }
}

/** A set's records answering `q`: headed exactly, or led. */
const recordsFor = (set: Value<'set'>, q: Question): Iterable<Value> =>
  q.exact !== undefined
    ? ledBy(set, 'record', [q.exact], q.marked)
    : ledHeads(set, q.marked, q.led!)

/** Finds read, asked and built, through the factory `f`. */
export function finds(f: Factory = value) {
  const o = objects(f)
  const sh = shapes(f)
  const s = searches(f)
  const q = {
    of: f.sym('of'),
    hole: f.sym('hole'),
    asked: f.sym('asked'),
    where: f.sym('where'),
    gives: f.sym('gives'),
    holds: f.sym('holds'),
    parts: f.sym('parts'),
    why: f.sym('why'),
  } as const
  const kind = {
    searchSpace: f.sym('search-space'),
    find: f.sym('find'),
    distinct: f.sym('distinct'),
    count: f.sym('count'),
    why: f.sym('why'),
    ranked: f.sym('ranked'),
    cat: f.sym('cat'),
    alt: f.sym('alt'),
    feed: f.sym('feed'),
    merge: f.sym('merge'),
    more: f.sym('more'),
  } as const
  const form = {
    within: f.sym('within'),
    as: f.sym('as'),
    any: f.sym('any'),
    all: f.sym('all'),
    quote: f.sym('quote'),
  } as const
  const formHeads = [form.within, form.any, form.all, form.as, form.quote]
  const findKinds = [
    kind.searchSpace,
    kind.find,
    kind.distinct,
    kind.count,
    kind.why,
  ]

  const isForm = (p: Value): boolean =>
    p.kind === 'record' && p.mark && formHeads.some(h => eq(h, p.head))

  /** Whether `v` is a find. */
  const findLike = (v: Value): boolean =>
    o.hasKind(v, kind.searchSpace) && o.hasKind(v, kind.find)
  const isFind = (v: Value): v is Value<'set'> => findLike(v)

  // ================ reading ================

  /** The forms in a clause, checked: each says what it needs. Nothing under a quote is a form. */
  function checkForms(c: Value, holes: Value<'set'>) {
    const check = (x: Value) => checkForms(x, holes)
    if (holes.has(c)) return
    if (c.kind === 'record' && isForm(c)) {
      const n = c.items.length - 1
      if (eq(c.head, form.quote)) {
        if (n !== 1) throw new SearchError('!(quote V) quotes one value')
        return
      }
      if (eq(c.head, form.within) && n !== 1)
        throw new SearchError('!(within P) has one part to look for')
      if (eq(c.head, form.as) && (n < 1 || n > 2 || !holes.has(c.items[1]!)))
        throw new SearchError(
          '!(as H P) binds a hole H, to what fits P if it says one'
        )
      if (n === 0) throw new SearchError('!(any …) and !(all …) need a part')
    }
    if (c.kind === 'list' || c.kind === 'record') c.items.forEach(check)
    else if (c.kind === 'set') for (const m of c.children()) check(m)
    else if (c.kind === 'dict')
      for (const [k, x] of c.entries()) {
        check(k)
        check(x)
      }
  }

  /**
   * A find, read. Refuses a value that isn't one, a kind it doesn't read,
   * counting together with saying why, an asked hole that isn't a hole, and a
   * form without what it needs.
   */
  function readFind(v: Value): Find {
    if (!isFind(v)) throw new SearchError('not a find')
    for (const k of o.kinds(v))
      if (!findKinds.some(x => eq(x, k)))
        throw new SearchError("a kind a find doesn't read: " + said(k))
    const has = (k: Value) => o.hasKind(v, k)
    const holes = f.set(answers(v, q.hole))
    const asked = [...answers(v, q.asked)]
    for (const h of asked)
      if (!holes.has(h)) throw new SearchError('asked binds a hole: ' + said(h))
    const wheres = [...answers(v, q.where)]
    for (const w of wheres) checkForms(w, holes)
    const found: Find = {
      of: [...answers(v, q.of)],
      holes,
      asked,
      wheres,
      gives: [...answers(v, q.gives)],
      distinct: has(kind.distinct),
      count: has(kind.count),
      why: has(kind.why),
    }
    if (found.count && found.why)
      throw new SearchError('a count has no parts to say why')
    return found
  }

  const said = (v: Value) =>
    v.kind === 'symbol' ? v.payload : '(a ' + v.kind + ')'

  /** A find written down: an object of its kinds, going by `id`. */
  function find(
    parts: {
      of?: Value[]
      holes?: Value[]
      asked?: Value[]
      wheres?: Value[]
      gives?: Value[]
      kinds?: ('distinct' | 'count' | 'why')[]
    },
    id: Value = o.randomId()
  ): Value<'set'> {
    const as = (question: Value, xs: Value[] = []) =>
      xs.map(x => o.answered(question, x))
    return o.describe(
      [kind.searchSpace, kind.find, ...(parts.kinds ?? []).map(k => kind[k])],
      id,
      ...as(q.of, parts.of),
      ...as(q.hole, parts.holes),
      ...as(q.asked, parts.asked),
      ...as(q.where, parts.wheres),
      ...as(q.gives, parts.gives)
    ) as Value<'set'>
  }

  // ================ subjects ================

  /** How a find is asked: names already followed on the way to it, and whether refusals are passed over. */
  type Asking = { followed: Value[]; skipRefused: boolean }

  const rankOrder = (a: Hit, b: Hit) =>
    cmp(a.record.items[1]!, b.record.items[1]!)

  /** A natural, of any size. */
  const isNatural = (v: Value) =>
    v.kind === 'number' && !v.mark && v.payload >= 0

  /**
   * A space holding its answers itself: every `holds` body, read as `fromValue`
   * reads one. A question, (Q) alone, is passed over; any other record that
   * isn't (Q A), or (Q R A) with R a natural when ranked, is refused unless
   * refusals are passed over.
   */
  function held(
    d: Value<'set'>,
    ranked: boolean,
    skipRefused: boolean
  ): Subject {
    const from = o.identityOf(d)
    const bodies = s.spaceBodies(d, ranked)
    const holds = (r: Value): r is Value<'record'> => {
      if (r.kind === 'record' && r.length === 1) return false
      const ok =
        r.kind === 'record' &&
        !r.mark &&
        (ranked ? r.length === 3 && isNatural(r.items[1]!) : r.length === 2)
      if (!ok && !skipRefused)
        throw new SearchError(
          'not a (query ' + (ranked ? 'rank ' : '') + 'answer) record'
        )
      return ok
    }
    const hit = (record: Value<'record'>): Hit => ({ record, from, ranked })
    const bodyHits = function* (
      b: Value<'set' | 'dict'>,
      q: Question | undefined
    ): Generator<Hit> {
      if (b.kind === 'dict') {
        if (q?.exact !== undefined) {
          const a = b.get(q.exact)
          if (a !== undefined) yield hit(f.record([q.exact, a]))
          return
        }
        for (const [k, a] of b.entries())
          if (q === undefined || ledHeadsOf(k, q.led!) === 0)
            yield hit(f.record([k, a]))
        return
      }
      const rs = q === undefined ? b.children() : recordsFor(b, q)
      if (!ranked || q !== undefined) {
        for (const r of rs) if (holds(r)) yield hit(r)
        return
      }
      // all of a ranked body, in rank order
      yield* [...rs].filter(holds).map(hit).sort(rankOrder)
    }
    const join = (qs: (Question | undefined)[]) =>
      ranked
        ? merge(rankOrder, ...qs.flatMap(q => bodies.map(b => bodyHits(b, q))))
        : alt(...qs.map(q => bodies.values().flatMap(b => bodyHits(b, q))))
    return {
      headed: qs => join(qs.filter(q => !q.marked)),
      all: () => join([undefined]),
    }
  }

  /** Where the head `k` sorts against those `led` asks for: 0 for one of them. */
  const ledHeadsOf = (k: Value, led: NonNullable<Question['led']>) =>
    against(k, led.kind, led.lead, led.mark)

  /** An object that isn't a search space: what it answers, (Q A), and its orders, !(Q A). */
  function thing(d: Value<'set'>): Subject {
    const from = o.identityOf(d)
    const answer = (r: Value): r is Value<'record'> =>
      r.kind === 'record' && r.length === 2
    const hit = (record: Value<'record'>): Hit => ({
      record,
      from,
      ranked: false,
    })
    return {
      headed: qs =>
        alt(...qs.map(q => stream(recordsFor(d, q)).filter(answer).map(hit))),
      all: () => d.children().filter(answer).map(hit),
    }
  }

  /** A search, which answers what it is asked and can't say what it holds. */
  function asking(search: Search<Value, Value>): Subject {
    let from: Value
    try {
      from = search.id()
    } catch {
      from = f.nil()
    }
    return {
      headed: qs =>
        alt(
          ...qs.map(q => {
            const head = q.exact ?? q.value
            return q.marked || head === undefined
              ? empty()
              : search.ask(head).map(a => ({
                  record: f.record([head, a]),
                  from,
                  ranked: false,
                }))
          })
        ),
      all: () => empty(),
    }
  }

  /** Parts joined as a composite of kind `k` joins them: one after another, merged by rank, or taking turns. */
  function joined(k: Value, parts: Subject[]): Subject {
    const join = (each: (p: Subject) => Iterable<Hit>): Iterable<Hit> =>
      eq(k, kind.cat)
        ? parts.values().flatMap(each)
        : eq(k, kind.merge)
          ? merge(rankOrder, ...parts.map(each))
          : alt(...parts.map(each))
    return {
      headed: qs => join(p => p.headed(qs)),
      all: () => join(p => p.all()),
    }
  }

  /**
   * Each answer of `first` asked of `then`, their records taking turns as
   * they arrive: (Q A) or (Q R A), as `then` answers A to `first`'s answer.
   * It can say all it holds when `first` can.
   */
  function fed(first: Subject, then: Subject): Subject {
    const through = (hits: Iterable<Hit>) =>
      altFrom(
        stream(hits).map(h =>
          stream(
            then.headed([
              { marked: false, exact: h.record.items[h.record.length - 1]! },
            ])
          ).map(t => ({
            record: f.record(
              t.ranked
                ? [h.record.items[0]!, t.record.items[1]!, t.record.items[2]!]
                : [h.record.items[0]!, t.record.items[1]!]
            ),
            from: t.from,
            ranked: t.ranked,
          }))
        )
      )
    return {
      headed: qs => through(first.headed(qs.filter(q => !q.marked))),
      all: () => through(first.all()),
    }
  }

  /**
   * The subject `v` is, read as `fromValue` reads a space and refusing what it
   * refuses: its names found through `resolve`, a name or find met again on
   * its own way round passed over. A part of a composite is a search ranked
   * as the composite is (`ranked`); what a find asks of directly may be any
   * object, ranked or not.
   */
  function subjectOf(
    v: Value,
    resolve: Resolve | undefined,
    how: Asking,
    within?: { ranked: boolean }
  ): Subject {
    if (!isObject(v) || o.kinds(v).next().done === true)
      return named(v, resolve, how, within)
    if (!o.hasKind(v, kind.searchSpace)) {
      if (within !== undefined)
        throw new SearchError('neither a search nor names of one')
      return thing(v)
    }
    if (isFind(v)) {
      if (within?.ranked)
        throw new SearchError("a find's answers are not ranked")
      return asking(findSearch(v, resolve, how))
    }
    const ranked = within?.ranked ?? o.hasKind(v, kind.ranked)
    const k = s.compositeOf(v, ranked)
    if (k === undefined) return held(v, ranked, how.skipRefused)
    if (eq(k, kind.more)) {
      if (ranked) throw new SearchError("a more's answers are not ranked")
      return asking(
        s.fromValue(v, { ...resolveFor(resolve), skipRefused: how.skipRefused })
      )
    }
    // each list of parts joined as the kind joins them, and several lists so
    // too; a feed's first part answers what its second is asked
    const made = s.partsOf(v).map(l => {
      if (eq(k, kind.feed)) {
        if (l.length !== 2) throw new SearchError('a feed has two parts')
        return fed(
          subjectOf(l.items[0]!, resolve, how, { ranked: false }),
          subjectOf(l.items[1]!, resolve, how, { ranked })
        )
      }
      return joined(
        k,
        l.items.map(p => subjectOf(p, resolve, how, { ranked }))
      )
    })
    return made.length === 1
      ? made[0]!
      : joined(eq(k, kind.feed) ? kind.alt : k, made)
  }

  /** A resolve as fromValue takes it. */
  const resolveFor = (resolve: Resolve | undefined) =>
    resolve === undefined
      ? {}
      : { resolve: s.search((n: Value) => ask(resolve, n)) }

  const ask = (resolve: Resolve, names: Value): Iterable<Found> =>
    resolve instanceof Search ? resolve.ask(names) : resolve(names)

  /**
   * What names stand for: asked, each name not yet followed is asked of
   * `resolve`, as things stand then, and each thing found answers in turn,
   * once however many names find it. Refuses names with nothing to resolve
   * them.
   */
  function named(
    names: Value,
    resolve: Resolve | undefined,
    how: Asking,
    within?: { ranked: boolean }
  ): Subject {
    if (resolve === undefined)
      throw new SearchError('names a space, with nothing to resolve it')
    const found = function* (): Generator<Subject> {
      const fresh = [...o.identities(names)].filter(
        n => !how.followed.some(m => eq(m, n))
      )
      const now = { ...how, followed: [...how.followed, ...fresh] }
      const seen: Found[] = []
      for (const n of fresh)
        for (const d of ask(resolve, n)) {
          const same = (x: Found) =>
            x instanceof Search || d instanceof Search ? x === d : eq(x, d)
          if (seen.some(same)) continue
          seen.push(d)
          yield d instanceof Search
            ? asking(d)
            : subjectOf(d, resolve, now, within)
        }
    }
    return {
      headed: qs => found().flatMap(p => p.headed(qs)),
      all: () => found().flatMap(p => p.all()),
    }
  }

  // ================ asking ================

  /**
   * The fits of a find's clauses, the forms read their own way, and `wild`, a
   * part that fits anything and binds nothing, standing in for the rank a
   * clause of two fields passes over.
   */
  function fitsFor(holes: Value<'set'>, wild: Value) {
    const forms: Forms = {
      is: isForm,
      fit: (p, v, fit) => {
        const r = p as Value<'record'>
        const parts = r.items.slice(1)
        if (eq(r.head, form.quote))
          return eq(parts[0]!, v) ? b => just(b) : () => empty()
        if (eq(r.head, form.any))
          return b => alt(...parts.map(x => fit(x, v)(b)))
        if (eq(r.head, form.as)) {
          const [hole, inner] = parts as [Value, Value?]
          return b => {
            const was = b.get(hole)
            if (was !== undefined && !eq(was, v)) return empty()
            const bound =
              was === undefined ? f.dict([...b.entries(), [hole, v]]) : b
            return inner === undefined ? just(bound) : fit(inner, v)(bound)
          }
        }
        if (eq(r.head, form.all))
          return parts
            .map(x => fit(x, v))
            .reduce(
              (a, c) =>
                function* (b) {
                  for (const b2 of a(b)) yield* c(b2)
                }
            )
        // within: v or anything in it
        return b => once(walk(v).flatMap(x => fit(parts[0]!, x)(b)))
      },
    }
    return sh.fitting({ example: f.nil(), holes, wild }, forms)
  }

  /** Each binding once. */
  function* once(found: Iterable<Bindings>): Generator<Bindings> {
    const seen = new BTreeSet<Value>(cmp)
    for (const b of found) {
      if (seen.has(b)) continue
      seen.add(b)
      yield b
    }
  }

  /** The holes in `c` the bindings leave unbound, each once; none under a quote. */
  function unbound(c: Value, holes: Value<'set'>, b: Bindings): number {
    const open = new BTreeSet<Value>(cmp)
    const look = (p: Value) => {
      if (holes.has(p)) {
        if (!b.has(p)) open.add(p)
        return
      }
      if (isForm(p) && eq((p as Value<'record'>).head, form.quote)) return
      if (p.kind === 'list' || p.kind === 'record') p.items.forEach(look)
      else if (p.kind === 'set') for (const x of p.children()) look(x)
      else if (p.kind === 'dict')
        for (const [k, x] of p.entries()) {
          look(k)
          look(x)
        }
    }
    look(c)
    return open.size
  }

  /**
   * Whether `v` fits exactly one value, once filled from `b`: an atom, a hole
   * bound, a quote, an `as` whose hole is bound or whose part is exact, an
   * `all` with an exact part. A list, record, dict or set fits more than
   * itself, and is never exact.
   */
  function exact(v: Value, holes: Value<'set'>, b: Bindings): boolean {
    if (holes.has(v)) return b.has(v)
    if (isForm(v)) {
      const [head, ...parts] = (v as Value<'record'>).items
      if (eq(head!, form.quote)) return true
      if (eq(head!, form.as))
        return (
          b.has(parts[0]!) || (parts.length === 2 && exact(parts[1]!, holes, b))
        )
      if (eq(head!, form.all)) return parts.some(p => exact(p, holes, b))
      return false
    }
    return !(
      v.kind === 'list' ||
      v.kind === 'record' ||
      v.kind === 'set' ||
      v.kind === 'dict'
    )
  }

  /** Whether `v` holds no unbound hole and no form but an exact one: so filled, it is one value. */
  function settled(v: Value, holes: Value<'set'>, b: Bindings): boolean {
    if (holes.has(v) || isForm(v)) return exact(v, holes, b)
    if (v.kind === 'list' || v.kind === 'record')
      return v.items.every(x => settled(x, holes, b))
    if (v.kind === 'set') return v.children().every(x => settled(x, holes, b))
    if (v.kind === 'dict')
      return v
        .entries()
        .every(([k, x]) => settled(k, holes, b) && settled(x, holes, b))
    return true
  }

  /** The settled `v` as one value: its holes filled from `b`, its exact forms what they fit. */
  function valueOf(v: Value, holes: Value<'set'>, b: Bindings): Value {
    if (holes.has(v)) return b.get(v)!
    if (isForm(v)) {
      const [head, ...parts] = (v as Value<'record'>).items
      if (eq(head!, form.quote)) return parts[0]!
      if (eq(head!, form.as))
        return b.get(parts[0]!) ?? valueOf(parts[1]!, holes, b)
      return valueOf(parts.find(p => exact(p, holes, b))!, holes, b)
    }
    const each = (x: Value) => valueOf(x, holes, b)
    switch (v.kind) {
      case 'list':
        return f.list(v.items.map(each), v.mark)
      case 'record':
        return f.record(v.items.map(each), v.mark)
      case 'dict':
        return f.dict(
          v.entries().map(([k, x]) => [each(k), each(x)]),
          v.mark
        )
      case 'set':
        return f.set(v.children().map(each), v.mark)
      default:
        return v
    }
  }

  /** The questions of the one value `w`: its head exactly if it is a record, and none if it isn't, since then no record fits. */
  const questionIn = (w: Value): Question[] =>
    w.kind === 'record' ? [{ marked: w.mark, exact: w.head }] : []

  type Head = Omit<Question, 'marked'>

  /**
   * The heads a clause's head `p` can be under `b`: exactly one value, or a
   * list or record led by its exact leading members, as a shape's list or
   * record fits any that begins with its members. Undefined when it could be
   * anything, a set or dict among them.
   */
  function headsOf(
    p: Value,
    holes: Value<'set'>,
    b: Bindings
  ): Head[] | undefined {
    if (exact(p, holes, b)) return [{ exact: valueOf(p, holes, b) }]
    if (holes.has(p)) return undefined
    if (isForm(p)) {
      const [head, ...parts] = (p as Value<'record'>).items
      if (eq(head!, form.as) && parts.length === 2)
        return headsOf(parts[1]!, holes, b)
      if (eq(head!, form.all))
        return firstOf(parts.map(x => headsOf(x, holes, b)))
      if (eq(head!, form.any))
        return unionOf(parts.map(x => headsOf(x, holes, b)))
      return undefined
    }
    if (p.kind !== 'list' && p.kind !== 'record') return undefined
    const lead: Value[] = []
    for (const x of p.items) {
      if (!exact(x, holes, b)) break
      lead.push(valueOf(x, holes, b))
    }
    const led = { kind: p.kind, lead, mark: p.mark }
    return [
      settled(p, holes, b) ? { led, value: valueOf(p, holes, b) } : { led },
    ]
  }

  /** The first that is known, an exact one before others. */
  const firstOf = <Q extends Head>(
    each: (Q[] | undefined)[]
  ): Q[] | undefined =>
    each.find(qs => qs !== undefined && qs.every(q => q.exact !== undefined)) ??
    each.find(qs => qs !== undefined)

  /** All of them, when each is known: the same exact question once. */
  function unionOf<Q extends Head>(each: (Q[] | undefined)[]): Q[] | undefined {
    if (each.some(qs => qs === undefined)) return undefined
    const seen = new BTreeSet<Value>(cmp)
    return (each as Q[][]).flat().filter(q => {
      if (q.exact === undefined) return true
      const key = f.record([q.exact], 'marked' in q && (q as Question).marked)
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })
  }

  /**
   * The questions a clause asks under `b`: the records it can fit, by their
   * heads, each found by bisecting, and none for a clause no record fits.
   * Undefined when they could be any, and every record must be looked at.
   */
  function questionsOf(
    c: Value,
    holes: Value<'set'>,
    b: Bindings
  ): Question[] | undefined {
    if (exact(c, holes, b)) return questionIn(valueOf(c, holes, b))
    if (holes.has(c)) return undefined
    if (isForm(c)) {
      const [head, ...parts] = (c as Value<'record'>).items
      if (eq(head!, form.as) && parts.length === 2)
        return questionsOf(parts[1]!, holes, b)
      if (eq(head!, form.all))
        return firstOf(parts.map(x => questionsOf(x, holes, b)))
      if (eq(head!, form.any))
        return unionOf(parts.map(x => questionsOf(x, holes, b)))
      return undefined
    }
    // an atom, list, dict or set fits no record
    if (c.kind !== 'record') return []
    return headsOf(c.head, holes, b)?.map(h => ({ ...h, marked: c.mark }))
  }

  /**
   * The clause `c` as it meets a ranked record (Q R A): a record of two fields
   * with `wild` in the rank's place, and so the record parts of the forms
   * that meet the record itself. Holes and forms still meet the record as
   * held, its rank and all.
   */
  function rankless(c: Value, wild: Value, holes: Value<'set'>): Value {
    if (c.kind !== 'record' || holes.has(c)) return c
    if (!isForm(c))
      return c.length === 2
        ? f.record([c.items[0]!, wild, c.items[1]!], c.mark)
        : c
    if (eq(c.head, form.any) || eq(c.head, form.all))
      return f.record(
        [c.head, ...c.items.slice(1).map(x => rankless(x, wild, holes))],
        true
      )
    if (eq(c.head, form.as) && c.length === 3)
      return f.record(
        [c.head, c.items[1]!, rankless(c.items[2]!, wild, holes)],
        true
      )
    return c
  }

  type Pending = { b: Bindings; why: Because[] }

  /** What a find needs while its clauses are fitted. */
  type Fitting = {
    holes: Value<'set'>
    wild: Value
    fit: (part: Value, v: Value) => Fit
    subjects: Subject[]
    /** whether the parts that answered are said, so a binding counts once per part */
    why: boolean
  }

  /**
   * Every extension of `p` under which one of the subjects' records fits the
   * clause `c`: each once, or once for each part that answers it when the
   * find says why.
   */
  function* step(c: Value, p: Pending, x: Fitting): Generator<Pending> {
    const questions = questionsOf(c, x.holes, p.b)
    const hits = alt(
      ...x.subjects.map(s =>
        questions === undefined ? s.all() : s.headed(questions)
      )
    )
    const given = new BTreeSet<Value>(cmp)
    const ranklessly = rankless(c, x.wild, x.holes)
    for (const hit of hits)
      for (const b of x.fit(hit.ranked ? ranklessly : c, hit.record)(p.b)) {
        const key = x.why ? f.list([b, hit.from]) : b
        if (given.has(key)) continue
        given.add(key)
        yield { b, why: [...p.why, { clause: c, from: hit.from }] }
      }
  }

  /**
   * The clauses fed one into the next, the next chosen each time: one that
   * only checks, then one whose question is settled, then any other, fewest
   * holes unbound first. A clause that only checks is asked for one answer,
   * or one for each part that answers it when the find says why. What each
   * binding leads to takes turns, so none starves the others.
   */
  function* through(
    clauses: Value[],
    p: Pending,
    x: Fitting
  ): Generator<Pending> {
    if (clauses.length === 0) {
      yield p
      return
    }
    const rank = (c: Value): [number, number] => {
      const open = unbound(c, x.holes, p.b)
      if (open === 0) return [0, 0]
      return [questionsOf(c, x.holes, p.b) === undefined ? 2 : 1, open]
    }
    let best = 0
    let bestRank = rank(clauses[0]!)
    for (let i = 1; i < clauses.length; i++) {
      const r = rank(clauses[i]!)
      if (r[0] < bestRank[0] || (r[0] === bestRank[0] && r[1] < bestRank[1])) {
        best = i
        bestRank = r
      }
    }
    const c = clauses[best]!
    const rest = clauses.filter((_, i) => i !== best)
    const found = step(c, p, x)
    if (bestRank[0] === 0 && !x.why) {
      const one = pull(found)
      if (one !== undefined) yield* through(rest, one, x)
      return
    }
    yield* altFrom(found.map(next => through(rest, next, x)))
  }

  /**
   * The holes of `holes` that `w` needs bound to be written: those in it, a
   * find within it keeping its own, whole, and so `kept`, the holes of finds
   * it is within.
   */
  function needs(
    w: Value,
    holes: Value<'set'>,
    into: BTreeSet<Value>,
    kept: Value<'set'> = f.set()
  ) {
    if (holes.has(w)) {
      into.add(w)
      return
    }
    if (kept.has(w)) return
    if (w.kind === 'set' && findLike(w)) {
      const own = f.set(answers(w, q.hole))
      const outer = f.set(holes.children().filter(h => !own.has(h)))
      const keep = f.set([...kept.children(), ...own.children()])
      for (const m of w.children()) needs(m, outer, into, keep)
      return
    }
    const each = (x: Value) => needs(x, holes, into, kept)
    if (w.kind === 'list' || w.kind === 'record') w.items.forEach(each)
    else if (w.kind === 'set') for (const x of w.children()) each(x)
    else if (w.kind === 'dict')
      for (const [k, x] of w.entries()) {
        each(k)
        each(x)
      }
  }

  /**
   * `w` with each hole of `holes` filled from `b`, which binds every one it
   * needs. A find within it keeps its own holes, asks of `of` when it says
   * nothing to ask of, and goes by each of its names, filled, with every
   * binding it was filled from, so each filling is a thing of its own.
   */
  function fill(
    w: Value,
    b: Bindings,
    holes: Value<'set'>,
    of: Value[],
    kept: Value<'set'> = f.set()
  ): Value {
    if (holes.has(w)) return b.get(w)!
    if (kept.has(w)) return w
    if (w.kind === 'set' && findLike(w)) {
      const own = f.set(answers(w, q.hole))
      const outer = f.set(holes.children().filter(h => !own.has(h)))
      const keep = f.set([...kept.children(), ...own.children()])
      const used = new BTreeSet<Value>(cmp)
      needs(w, holes, used, kept)
      const by = f.dict([...used].map(h => [h, b.get(h)!] as [Value, Value]))
      const members = w.children().map(m => {
        if (
          used.size === 0 ||
          m.kind !== 'record' ||
          m.mark ||
          m.length !== 2 ||
          !eq(m.head, o.q.identity)
        )
          return fill(m, b, outer, of, keep)
        // a name goes with every binding the filling used
        return o.answered(
          o.q.identity,
          f.list([fill(m.items[1]!, b, outer, of, keep), by])
        )
      })
      const asks =
        answers(w, q.of).next().done === true
          ? of.map(x => o.answered(q.of, x))
          : []
      return f.set([...members, ...asks], true)
    }
    const each = (x: Value) => fill(x, b, holes, of, kept)
    switch (w.kind) {
      case 'list':
        return f.list(w.items.map(each), w.mark)
      case 'record':
        return f.record(w.items.map(each), w.mark)
      case 'dict':
        return f.dict(
          w.entries().map(([k, x]) => [each(k), each(x)]),
          w.mark
        )
      case 'set':
        return f.set(w.children().map(each), w.mark)
      default:
        return w
    }
  }

  /** How `evaluate` and `findSearch` are asked. */
  type Options = {
    /** what names are found as */
    resolve?: Resolve
    /** pass over records a space can't hold, rather than refuse them */
    skipRefused?: boolean
    /** names already followed on the way here, passed over if met again */
    followed?: Value[]
  }

  /**
   * Every answer of the find `query`, asked `asked`, with the bindings it was
   * written from and which part answered each clause: one per pull, nothing
   * worked out ahead. Its names are found through `resolve` as they are
   * needed. Refuses what isn't a find, as `readFind` does, and, as `fromValue`
   * does, a subject it can't read.
   */
  function evaluate(
    query: Value,
    opts: Options & { asked?: Value } = {}
  ): Stream<Row> {
    return stream(rowsOf(query, readFind(query), opts.asked, opts))
  }

  function* rowsOf(
    query: Value,
    fd: Find,
    asked: Value | undefined,
    opts: Options
  ): Generator<Row> {
    const start = f.dict(
      asked === undefined ? [] : fd.asked.map(h => [h, asked] as [Value, Value])
    )
    const how: Asking = {
      followed: [
        ...(opts.followed ?? []),
        ...o.identities(o.identityOf(query)),
      ],
      skipRefused: opts.skipRefused ?? false,
    }
    const wild = o.randomId()
    const x: Fitting = {
      holes: fd.holes,
      wild,
      fit: fitsFor(fd.holes, wild),
      subjects: fd.of.map(v => subjectOf(v, opts.resolve, how)),
      why: fd.why,
    }
    const bound = new BTreeSet<Value>(cmp)
    const answered = new BTreeSet<Value>(cmp)
    let count = 0
    for (const p of through(fd.wheres, { b: start, why: [] }, x)) {
      const parts = f.set(p.why.map(w => w.from))
      const key = fd.why ? f.list([p.b, parts]) : p.b
      if (bound.has(key)) continue
      bound.add(key)
      const written =
        fd.gives.length === 0
          ? [p.b]
          : fd.gives
              .filter(g => {
                const want = new BTreeSet<Value>(cmp)
                needs(g, fd.holes, want)
                return [...want].every(h => p.b.has(h))
              })
              .map(g => fill(g, p.b, fd.holes, fd.of))
      for (let answer of written) {
        if (fd.distinct) {
          if (answered.has(answer)) continue
          answered.add(answer)
        }
        if (fd.count) answer = f.number(++count)
        else if (fd.why) answer = f.record([q.why, answer, parts])
        yield { answer, bindings: p.b, why: p.why }
      }
    }
  }

  /**
   * The search a find stands for: asked, it answers as `evaluate` does, its
   * asked holes bound to what it is asked. Written down, it is the find.
   */
  function findSearch(
    d: Value,
    resolve?: Resolve,
    how: Partial<Asking> = {}
  ): Search<Value, Value> {
    const fd = readFind(d)
    const id = o.identityOf(d)
    const opts: Options = { ...how }
    if (resolve !== undefined) opts.resolve = resolve
    return new Search<Value, Value>(
      asked => rowsOf(d, fd, asked, opts).map(r => r.answer),
      () => d,
      () => id
    )
  }

  return { kind, form, isFind, readFind, find, evaluate, findSearch } as const
}
