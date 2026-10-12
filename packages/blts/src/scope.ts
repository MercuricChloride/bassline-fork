// Scopes: the searches in reach where a question comes up.
//
// A scope holds the searches put in it, each for a question, and sits inside
// the scope around it. Asking a question there asks every search in reach
// that answers it, nearest first: those a scope reaches before its own (the
// `nearer` scopes, reached when a question gets there), then its own in the
// order they were put, then the scope around it, out to the outermost.
// Nothing fixes which questions exist or who answers them: put a search in a
// scope and everything asking from there, or from inside it, hears from it.
//
// A question is named. The name is what a search is put for and what asking
// matches; the query and answer types ride along for TypeScript's sake only,
// so two questions with one name are one question, and a search put for one
// is handed the queries of the other. That is the price of keeping questions
// open to anyone who knows the name: name a question for what it asks.
//
// Nothing is asked ahead of a pull, and every pull sees the scopes as they
// are then: a search put after the asking but before the stream reaches its
// scope is heard.

import { asSearch, Search, type Asks } from './search.ts'
import { alt, type Stream } from './stream.ts'

/** A question by its name, with what it asks and what answers it. */
export interface Question<Q, A> {
  readonly name: string
  /** Never set: carries the query and answer types. */
  readonly types?: (q: Q) => A
}

/** The question called `name`, taking `Q` and answered by `A`. */
export const question = <Q, A>(name: string): Question<Q, A> => ({ name })

/**
 * A search in reach, and where it was found: the scope it was put in, its
 * place among that scope's searches, and how many scopes out from where the
 * question was asked (0: right there).
 */
export type InReach<Q, A> = {
  search: Search<Q, A>
  scope: Scope
  index: number
  out: number
}

type Put = { question: string; search: Search<any, any> }

export class Scope {
  readonly parent: Scope | undefined
  /** What to call it where the searches in reach are listed. A label only; nothing is looked up by it. */
  readonly name: string | undefined
  readonly #nearer: (() => Iterable<Scope>) | undefined
  #put: Put[] = []

  constructor(
    opts: {
      parent?: Scope
      name?: string
      /** Scopes reached before this one's own searches, each when a question gets there. */
      nearer?: () => Iterable<Scope>
    } = {}
  ) {
    this.parent = opts.parent
    this.name = opts.name
    this.#nearer = opts.nearer
  }

  /** Puts `search` here, answering `q`, after the searches already put for it. */
  put<Q, A>(q: Question<Q, A>, search: Asks<Q, A>): this {
    this.#put = [...this.#put, { question: q.name, search: asSearch(search) }]
    this.changed()
    return this
  }

  /** Takes `search` out, wherever it was put for `q`. */
  remove<Q, A>(q: Question<Q, A>, search: Search<Q, A>): this {
    this.#put = this.#put.filter(
      p => !(p.question === q.name && p.search === search)
    )
    this.changed()
    return this
  }

  /** Called whenever what is put here changes: a hook for whatever watches it. */
  protected changed(): void {}

  /** Called whenever what is put here is read: a hook for whatever watches it. */
  protected read(): void {}

  /** The searches put here, not around here, for `q`, with where each was put. */
  #here<Q, A>(q: Question<Q, A>): [number, Search<Q, A>][] {
    this.read()
    const found: [number, Search<Q, A>][] = []
    this.#put.forEach((p, i) => {
      if (p.question === q.name) found.push([i, p.search])
    })
    return found
  }

  /** The scopes a question asked here reaches, nearest first, each reached when the stream gets there. */
  *segments(): Generator<Scope, void, unknown> {
    for (let s: Scope | undefined = this; s !== undefined; s = s.parent) {
      if (s.#nearer !== undefined) yield* s.#nearer()
      yield s
    }
  }

  /** Every search in reach answering `q`, nearest first, with where it was found. */
  *reach<Q, A>(q: Question<Q, A>): Generator<InReach<Q, A>, void, unknown> {
    let out = 0
    for (const scope of this.segments()) {
      for (const [index, search] of scope.#here(q))
        yield { search, scope, index, out }
      out++
    }
  }

  /** Every search in reach answering `q`, nearest first. */
  *searches<Q, A>(q: Question<Q, A>): Generator<Search<Q, A>, void, unknown> {
    for (const scope of this.segments())
      for (const [, search] of scope.#here(q)) yield search
  }

  /**
   * Asks `query` of every search in reach answering `q`, taking turns between
   * their streams so no endless one starves the rest. Searches are asked
   * lazily, nearest first, so the first answers come in the order the
   * searches are in reach; after that each live stream gives one answer a
   * round.
   */
  *ask<Q, A>(q: Question<Q, A>, query: Q): Generator<A, void, unknown> {
    const live: Stream<A>[] = []
    for (const search of this.searches(q)) {
      const answers = search.ask(query)
      const first = answers.next()
      if (first.done) continue
      live.push(answers)
      yield first.value
    }
    yield* alt(...live)
  }

  /** The first answer to `query` from what is in reach, or undefined. */
  first<Q, A>(q: Question<Q, A>, query: Q): A | undefined {
    for (const a of this.ask(q, query)) return a
    return undefined
  }

  /**
   * Asks `query` of each search in reach on its own, nearest first, and
   * answers with those that answer it, each with its first answer: who
   * answers this question here, and from where. Each pull asks searches until
   * one answers.
   */
  *replay<Q, A>(
    q: Question<Q, A>,
    query: Q
  ): Generator<[InReach<Q, A>, A], void, unknown> {
    for (const found of this.reach(q)) {
      const first = found.search.first(query)
      if (first !== undefined) yield [found, first]
    }
  }

  /** The question `q` as one search, answered by everything in reach here, to compose and hand on. */
  search<Q, A>(q: Question<Q, A>): Search<Q, A> {
    return new Search<Q, A>(query => this.ask(q, query))
  }
}

export type { Stream }
