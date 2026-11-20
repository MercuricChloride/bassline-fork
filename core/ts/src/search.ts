// Searches: what you ask, handing back a stream you pull. A port of blnim's
// queries/search.nim.
//
// A search closes over whatever it answers from; how it got there is its own
// construction. Searches compose into new searches: one after another (`cat`,
// as a scope falls back to the scope around it), taking turns (`alt`),
// answers fed on as questions (`feed`), and one search's answers asked of it
// again, nearest first (`more`).
//
// Some searches can also be written down: their space denoted as an object,
// which `fromValue` turns back into a search. Most never are, since most
// spaces aren't worth the bytes, but one that is can be talked about like any
// value. Its kinds, together, say how to bring it about:
//
//   !{!(kind search-space) (identity ID) (holds {(Q A) …})}
//   !{!(kind search-space) (identity ID) (holds {Q: A …})}     ; one answer a query
//   !{!(kind search-space) !(kind cat) (identity ID) (parts [PART …])}
//
// and `alt` and `feed` like `cat`, and `more` with one part, `!(kind via)` with
// it answering the way each answer was reached. A part is an object, or names of a thing
// written down elsewhere, asked of a search of known spaces when the search is
// asked. A one-field record (Q) in a space is a question, Q being asked, not
// an answer; it sorts after Q's answers, so a query's run holds both, and
// answering passes over it. Ranked spaces, and `merge`, are not read here yet.

import { BTreeSet } from './btree.ts'
import { answers, headed, isObject, objects } from './object.ts'
import { finds } from './query.ts'
import {
  altFrom,
  alt as altStreams,
  empty,
  stream,
  type Stream,
} from './stream.ts'
import { cmp, eq, type Factory, type Value } from './types.ts'
import { value } from './values.ts'

/** A search, or a plain function that asks like one. */
export type Asks<Q, A> = Search<Q, A> | ((q: Q) => Iterable<A>)

/** A denotation that can't be read back as a search. */
export class SearchError extends Error {}

/**
 * What an answer's reading throws to refuse a value it cannot hold. A search
 * read back with `skipRefused` passes over these, and only these: anything
 * else a reading throws is a fault, and goes on up.
 */
export class Refused extends Error {}

/**
 * Something you ask: `ask(q)` hands back a stream of answers to pull. It may
 * write its space down (`toValue`) and say the ID it goes by (`id`) without
 * writing it down.
 */
export class Search<Q, A> {
  readonly #asking: (q: Q) => Iterable<A>
  readonly #denoting: (() => Value) | undefined
  readonly #identifying: (() => Value) | undefined

  constructor(
    ask: (q: Q) => Iterable<A>,
    denote?: () => Value,
    id?: () => Value
  ) {
    this.#asking = ask
    this.#denoting = denote
    this.#identifying = id
  }

  /** Every answer to `q`, as a stream. */
  ask(q: Q): Stream<A> {
    return stream(this.#asking(q))
  }

  /** The first answer to `q`, or undefined when there is none. */
  first(q: Q): A | undefined {
    for (const a of this.#asking(q)) return a
    return undefined
  }

  get denotable() {
    return this.#denoting !== undefined
  }

  /** The search written down. Refuses a search that has no denotation. */
  toValue(): Value {
    if (this.#denoting === undefined)
      throw new SearchError('this search has no denotation')
    return this.#denoting()
  }

  /**
   * The ID the search goes by. One built without an ID is asked for its
   * denotation instead, which may cost writing it all down.
   */
  id(): Value {
    if (this.#identifying !== undefined) return this.#identifying()
    const d = this.toValue()
    return isObject(d) ? objects().identityOf(d) : d
  }

  /** As it answers, written down with `denote` and going by `id`. */
  writtenAs(denote: (() => Value) | undefined, id: () => Value) {
    return new Search(this.#asking, denote, id)
  }

  /** Written down by its ID alone: a composite that holds it names it rather than carrying it whole. */
  byId(): Search<Q, A> {
    const name = () => this.id()
    return this.writtenAs(name, name)
  }
}

/** `s` as a `Search`, a function becoming one with no denotation. */
export const asSearch = <Q, A>(s: Asks<Q, A>): Search<Q, A> =>
  s instanceof Search ? s : new Search(s)

const SKIP = Symbol('skip')

/** Searches composed and read back, building values through the factory `f`. */
export function searches(f: Factory = value) {
  const o = objects(f)
  const kind = {
    searchSpace: f.sym('search-space'),
    ranked: f.sym('ranked'),
    cat: f.sym('cat'),
    alt: f.sym('alt'),
    feed: f.sym('feed'),
    merge: f.sym('merge'),
    more: f.sym('more'),
    via: f.sym('via'),
  } as const
  const composites = [kind.cat, kind.alt, kind.feed, kind.merge, kind.more]

  /** A search answering with `ask`, written down with `denote` if it can be, going by `id`. */
  function search<Q, A>(
    ask: (q: Q) => Iterable<A>,
    denote?: () => Value,
    id?: Value
  ): Search<Q, A> {
    return new Search(ask, denote, id === undefined ? undefined : () => id)
  }

  function partsDenoter(
    k: Value,
    id: Value,
    parts: Search<any, any>[]
  ): (() => Value) | undefined {
    if (!parts.every(p => p.denotable)) return undefined
    return () =>
      o.describe(
        [kind.searchSpace, k],
        id,
        o.answered(o.q.parts, f.list(parts.map(p => p.toValue())))
      )
  }

  /** Each part's answers in turn, a part asked only once the one before it has nothing more: a scope, then the scope around it. */
  function cat<Q, A>(parts: Asks<Q, A>[], id: Value = o.randomId()) {
    const ps = parts.map(asSearch)
    return new Search<Q, A>(
      function* (q) {
        for (const p of ps) yield* p.ask(q)
      },
      partsDenoter(kind.cat, id, ps),
      () => id
    )
  }

  /** The parts' answers taking turns, so no part starves the others. */
  function alt<Q, A>(parts: Asks<Q, A>[], id: Value = o.randomId()) {
    const ps = parts.map(asSearch)
    return new Search<Q, A>(
      q => altStreams(...ps.map(p => p.ask(q))),
      partsDenoter(kind.alt, id, ps),
      () => id
    )
  }

  /** Each answer of `first` asked of `then`, their streams taking turns as they arrive. */
  /**
   * `step` asked again of each answer it gives, nearest first: asked q, it
   * answers what `step` answers to q, then what it answers to each of those,
   * and so on, each value once, so a walk that comes round again ends.
   * Answers the same distance away take turns. With `via` each answer is
   * (via [Q … PREVIOUS] A), the values walked through to reach it.
   */
  function more(
    step: Asks<Value, Value>,
    id: Value = o.randomId(),
    via = false
  ) {
    const s = asSearch(step)
    type Walked = { value: Value; path: Value[] }
    return new Search<Value, Value>(
      function* (q) {
        const answered = new BTreeSet<Value>(cmp)
        const expanded = new BTreeSet<Value>(cmp)
        expanded.add(q)
        let level: Walked[] = [{ value: q, path: [] }]
        while (level.length > 0) {
          const next: Walked[] = []
          const reached = altStreams(
            ...level.map(w =>
              s
                .ask(w.value)
                .map(a => ({ value: a, path: [...w.path, w.value] }))
            )
          )
          for (const w of reached) {
            if (answered.has(w.value)) continue
            answered.add(w.value)
            if (!expanded.has(w.value)) {
              expanded.add(w.value)
              next.push(w)
            }
            yield via ? f.record([kind.via, f.list(w.path), w.value]) : w.value
          }
          level = next
        }
      },
      s.denotable
        ? () =>
            o.describe(
              via
                ? [kind.searchSpace, kind.more, kind.via]
                : [kind.searchSpace, kind.more],
              id,
              o.answered(o.q.parts, f.list([s.toValue()]))
            )
        : undefined,
      () => id
    )
  }

  function feed<Q, M, A>(
    first: Asks<Q, M>,
    then: Asks<M, A>,
    id: Value = o.randomId()
  ) {
    const a = asSearch(first)
    const b = asSearch(then)
    return new Search<Q, A>(
      q => altFrom(a.ask(q).map(m => b.ask(m))),
      partsDenoter(kind.feed, id, [a, b]),
      () => id
    )
  }

  /** Each record's answer, read back; a question, (Q) alone, passed over. */
  function* readBack<A>(
    records: Iterable<Value>,
    read: (v: Value) => A,
    skipRefused: boolean
  ) {
    for (const r of records) {
      if (r.kind !== 'record' || r.length === 1) continue
      if (r.length !== 2) {
        if (skipRefused) continue
        throw new SearchError('not a (query answer) record: ' + r.length)
      }
      const a = reading(r.items[1]!, read, skipRefused)
      if (a !== SKIP) yield a as A
    }
  }

  /** Each answer read by `read`, refusals passed over when `skipRefused`. */
  function* readAll<A>(
    answers: Iterable<Value>,
    read: (v: Value) => A,
    skipRefused: boolean
  ) {
    for (const v of answers) {
      const a = reading(v, read, skipRefused)
      if (a !== SKIP) yield a as A
    }
  }

  function reading<A>(v: Value, read: (v: Value) => A, skipRefused: boolean) {
    if (!skipRefused) return read(v)
    try {
      return read(v)
    } catch (e) {
      if (e instanceof Refused) return SKIP
      throw e
    }
  }

  /** Asking one body a space holds: a set's records headed by the query, or a dict's one entry. */
  function bodyAsk<A>(
    body: Value<'set' | 'dict'>,
    read: (v: Value) => A,
    skipRefused: boolean
  ): (q: Value) => Iterable<A> {
    if (body.kind === 'set')
      return q => readBack(headed(body, q), read, skipRefused)
    return q => {
      const a = body.get(q)
      return a === undefined
        ? empty()
        : readBack([f.record([q, a])], read, skipRefused)
    }
  }

  /**
   * A search over a set of records, or a dict, held now: each ask sees it as
   * it stands. Written down, it is the space as it stands then. A marked set
   * or dict is not a space, and is refused, as `fromValue` refuses one.
   */
  function searchOver<A = Value>(
    space: Value<'set' | 'dict'>,
    id: Value = o.randomId(),
    read: (v: Value) => A = v => v as A,
    skipRefused = false
  ) {
    if (space.mark)
      throw new SearchError('a space holds unmarked sets of records or dicts')
    const body = space
    return new Search<Value, A>(
      bodyAsk(body, read, skipRefused),
      () => o.describe([kind.searchSpace], id, o.answered(o.q.holds, body)),
      () => id
    )
  }

  /**
   * How a space's parts are read: a composite kind, or undefined for a space
   * holding its answers itself. Each kind says its own part: `search-space`
   * that it is a search, `ranked` that its answers are ranked, and a
   * composite kind how its parts are read. Refuses a kind it can't carry
   * out, two ways of reading the parts at once, a space ranked otherwise
   * than `ranked`, and a merge of unranked parts.
   */
  function compositeOf(d: Value, ranked: boolean): Value | undefined {
    for (const k of o.kinds(d)) {
      if (
        !composites.some(c => eq(c, k)) &&
        !eq(k, kind.searchSpace) &&
        !eq(k, kind.ranked) &&
        !eq(k, kind.via)
      )
        throw new SearchError("a kind this doesn't read: " + printK(k))
    }
    if (o.hasKind(d, kind.via) && !o.hasKind(d, kind.more))
      throw new SearchError('via is the way a more reached its answers')
    if (o.hasKind(d, kind.ranked) !== ranked)
      throw new SearchError(
        ranked
          ? 'an unranked space, read as ranked'
          : 'a ranked space, read as unranked'
      )
    const found = [...o.kinds(d)].filter(k => composites.some(c => eq(c, k)))
    if (found.length > 1)
      throw new SearchError('a search space read as two composites')
    if (found.length === 1 && eq(found[0]!, kind.merge) && !ranked)
      throw new SearchError('a merge is of ranked searches')
    return found[0]
  }

  /**
   * Everything a space holds: every `holds` answer, each a set of records or,
   * unranked, a dict. Refuses a space holding nothing, and a body it can't
   * hold.
   */
  function spaceBodies(d: Value, ranked: boolean): Value<'set' | 'dict'>[] {
    const bodies = [...answers(d, o.q.holds)].map(b => {
      if (!((b.kind === 'set' || (b.kind === 'dict' && !ranked)) && !b.mark))
        throw new SearchError(
          'a space holds sets of records' + (ranked ? '' : ' or dicts')
        )
      return b as Value<'set' | 'dict'>
    })
    if (bodies.length === 0)
      throw new SearchError('a space that holds nothing said')
    return bodies
  }

  /** The composite a space's `parts` answers list: each an unmarked list. Refuses any other, and none. */
  function partsOf(d: Value): Value<'list'>[] {
    const lists = [...answers(d, o.q.parts)].map(parts => {
      if (parts.kind !== 'list' || parts.mark)
        throw new SearchError("a composite's parts are a list")
      return parts
    })
    if (lists.length === 0)
      throw new SearchError('a composite with no parts said')
    return lists
  }

  const printK = (k: Value) =>
    k.kind === 'symbol' ? k.payload : '(a ' + k.kind + ')'

  /** What names are found as: spaces written down, or searches running here, taken as they are. */
  type Resolve = Search<Value, Value | Search<Value, Value>> | undefined

  let found: ReturnType<typeof finds> | undefined
  /** Finds, read the first time one is met. */
  const findsHere = () => (found ??= finds(f))

  function interpret<A>(
    d: Value,
    read: (v: Value) => A,
    skipRefused: boolean,
    resolve: Resolve,
    followed: Value[]
  ): Search<Value, A> {
    if (!o.hasKind(d, kind.searchSpace)) {
      if (o.kinds(d).next().done !== true)
        throw new SearchError('neither a search nor names of one')
      return named(d, read, skipRefused, resolve, followed)
    }
    if (findsHere().isFind(d)) {
      const answering = findsHere().findSearch(d, resolve, {
        followed,
        skipRefused,
      })
      return new Search<Value, A>(
        q => readAll(answering.ask(q), read, skipRefused),
        () => d,
        () => o.identityOf(d)
      )
    }
    const k = compositeOf(d, false)
    const id = o.identityOf(d)
    if (k === undefined) {
      const asks = spaceBodies(d, false).map(b => bodyAsk(b, read, skipRefused))
      return new Search<Value, A>(
        function* (q) {
          for (const ask of asks) yield* ask(q)
        },
        () => d,
        () => id
      )
    }
    const made = partsOf(d).map(parts => {
      if (eq(k, kind.more)) {
        if (parts.length !== 1) throw new SearchError('a more has one part')
        const walking = more(
          interpret(parts.items[0]!, v => v, skipRefused, resolve, followed),
          id,
          o.hasKind(d, kind.via)
        )
        return new Search<Value, A>(
          q => readAll(walking.ask(q), read, skipRefused),
          undefined,
          () => id
        )
      }
      if (eq(k, kind.feed)) {
        if (parts.length !== 2) throw new SearchError('a feed has two parts')
        return feed(
          interpret(parts.items[0]!, v => v, skipRefused, resolve, followed),
          interpret(parts.items[1]!, read, skipRefused, resolve, followed),
          id
        )
      }
      return combine(
        k,
        parts.items.map(p =>
          interpret(p, read, skipRefused, resolve, followed)
        ),
        id
      )
    })
    const whole = made.length === 1 ? made[0]! : combine(k, made, id)
    return whole.writtenAs(
      () => d,
      () => id
    )
  }

  const combine = <A>(k: Value, ps: Search<Value, A>[], id: Value) =>
    eq(k, kind.cat) ? cat(ps, id) : alt(ps, id)

  /**
   * The search a name stands for: asked, it asks `resolve` about each name,
   * as things stand then, and answers from each space found in turn. A name
   * already followed on the way here is passed over, so names that lead round
   * to themselves come to an end. Written down, it is the name again.
   */
  function named<A>(
    name: Value,
    read: (v: Value) => A,
    skipRefused: boolean,
    resolve: Resolve,
    followed: Value[]
  ): Search<Value, A> {
    if (resolve === undefined)
      throw new SearchError('names a space, with nothing to resolve it')
    return new Search<Value, A>(
      function* (q) {
        const fresh = [...o.identities(name)].filter(
          n => !followed.some(m => eq(m, n))
        )
        const now = [...followed, ...fresh]
        const seen: (Value | Search<Value, Value>)[] = []
        for (const n of fresh) {
          for (const d of resolve.ask(n)) {
            if (d instanceof Search) {
              if (seen.some(s => s === d)) continue
              seen.push(d)
              yield* readAll(d.ask(q), read, skipRefused)
              continue
            }
            if (seen.some(s => !(s instanceof Search) && eq(s, d))) continue
            seen.push(d)
            yield* interpret(d, read, skipRefused, resolve, now).ask(q)
          }
        }
      },
      () => name,
      () => name
    )
  }

  /**
   * The search a denotation stands for, written down again as exactly that.
   * A space answers a query from the records headed by it, each read back by
   * `read`; a refusal (`read` throwing `Refused`) is thrown on unless `skipRefused`.
   * Several `holds` or `parts` answers are all read, joined as the kind joins
   * its parts. A part that is only names is asked of `resolve` when the
   * search is asked, and a search it finds running here is asked as it is. A
   * find (`query.ts`) answers as its clauses find.
   */
  function fromValue<A = Value>(
    d: Value,
    opts: {
      read?: (v: Value) => A
      skipRefused?: boolean
      resolve?: Search<Value, Value | Search<Value, Value>>
    } = {}
  ): Search<Value, A> {
    return interpret(
      d,
      opts.read ?? (v => v as A),
      opts.skipRefused ?? false,
      opts.resolve,
      []
    )
  }

  return {
    kind,
    search,
    cat,
    alt,
    feed,
    more,
    searchOver,
    fromValue,
    compositeOf,
    spaceBodies,
    partsOf,
  } as const
}
