export type Search<K, V> = (key: K | null) => Stream<V>
export type Send<K, V> = (key: K | null, val: V) => boolean
export type BVar<K, V> = {
  search: Search<K, V>
  send: Send<K, V>
}

/** A stream, with the platform's iterator helpers. */
export type Stream<A> = IteratorObject<A, unknown, unknown>

/** What an iterable hands out. */
export type Answer<S> = S extends Iterable<infer A> ? A : never

/** A stream over `xs`, with the platform's iterator helpers. */
export function stream<A>(xs: Iterable<A>): Stream<A> {
  return Iterator.from(xs)
}

/** A stream with no answers. */
export function* empty<A = never>(): Generator<A, void, unknown> {}

/** A stream of `a` alone. */
export function* just<A>(a: A): Generator<A, void, unknown> {
  yield a
}

/** The stream `make` makes, made only when first pulled. */
export function* lazy<A>(make: () => Iterable<A>): Generator<A, void, unknown> {
  yield* make()
}

/**
 * The next answer, or undefined when the stream has nothing more; or, given
 * `n`, up to `n` answers, pulling no more than that. Either way the stream is
 * left open, to pull again.
 */
export function pull<A>(s: Iterator<A>): A | undefined
export function pull<A>(s: Iterator<A>, n: number): A[]
export function pull<A>(s: Iterator<A>, n?: number): A | undefined | A[] {
  if (n === undefined) {
    const r = s.next()
    return r.done ? undefined : r.value
  }
  const out: A[] = []
  while (out.length < n) {
    const r = s.next()
    if (r.done) break
    out.push(r.value)
  }
  return out
}

/**
 * Fair turns between the streams: one answer from each in order, round and
 * round, passing over those with nothing more, so an endless stream cannot
 * starve the others.
 */
export function alt<S extends Iterable<unknown>[]>(
  ...streams: S
): Generator<Answer<S[number]>, void, unknown>
export function* alt(
  ...streams: Iterable<unknown>[]
): Generator<unknown, void, unknown> {
  const live = streams.map(s => s[Symbol.iterator]())
  while (live.length > 0) {
    for (let i = 0; i < live.length; ) {
      const r = live[i]!.next()
      if (r.done) live.splice(i, 1)
      else {
        yield r.value
        i++
      }
    }
  }
}

/**
 * Fair turns over the streams `streams` hands out, admitting one more at the
 * start of each round, so neither an endless supply of streams nor one
 * endless stream starves the others.
 */
export function altFrom<S extends Iterable<unknown>>(
  streams: Iterable<S>
): Generator<Answer<S>, void, unknown>
export function* altFrom(
  streams: Iterable<Iterable<unknown>>
): Generator<unknown, void, unknown> {
  const supply = streams[Symbol.iterator]()
  const live: Iterator<unknown>[] = []
  let supplied = true
  while (supplied || live.length > 0) {
    if (supplied) {
      const next = supply.next()
      if (next.done) supplied = false
      else live.push(next.value[Symbol.iterator]())
    }
    for (let i = 0; i < live.length; ) {
      const r = live[i]!.next()
      if (r.done) live.splice(i, 1)
      else {
        yield r.value
        i++
      }
    }
  }
}

/**
 * Each stream in turn, the next pulled only once the one before has nothing
 * more: a later stream is never reached past an endless one.
 */
export function cat<S extends Iterable<unknown>[]>(
  ...streams: S
): Generator<Answer<S[number]>, void, unknown>
export function* cat(
  ...streams: Iterable<unknown>[]
): Generator<unknown, void, unknown> {
  for (const s of streams) yield* s
}

/** Each stream `streams` hands out, in turn, as `cat`. */
export function catFrom<S extends Iterable<unknown>>(
  streams: Iterable<S>
): Generator<Answer<S>, void, unknown>
export function* catFrom(
  streams: Iterable<Iterable<unknown>>
): Generator<unknown, void, unknown> {
  for (const s of streams) yield* s
}

/**
 * Streams each already in `order`, merged into one in order; on a tie the
 * earlier stream goes first. A stream is pulled again only once its last
 * answer has been taken.
 */
export function* merge<A>(
  order: (a: A, b: A) => number,
  ...streams: Iterable<A>[]
): Generator<A, void, unknown> {
  const its = streams.map(s => s[Symbol.iterator]())
  const heads = its.map(it => it.next())
  while (true) {
    let best: { at: number; value: A } | undefined
    heads.forEach((h, at) => {
      if (!h.done && (best === undefined || order(h.value, best.value) < 0))
        best = { at, value: h.value }
    })
    if (best === undefined) return
    yield best.value
    // pulled again only now, once its answer has been taken
    heads[best.at] = its[best.at]!.next()
  }
}

export function* filterMap<A, B>(
  s: Iterable<A>,
  fn: (a: A) => B | undefined
): Generator<B, void, unknown> {
  for (const a of s) {
    const b = fn(a)
    if (b !== undefined) yield b
  }
}

export function* tap<A>(
  s: Iterable<A>,
  fn: (a: A) => void
): Generator<A, void, unknown> {
  for (const a of s) {
    fn(a)
    yield a
  }
}
