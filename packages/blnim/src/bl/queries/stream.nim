## Streams: a pull, one answer at a time.
##
## A `Stream[A]` is a proc answering the next value, or none once there is
## nothing more, and a stream pulled again goes on from where it stopped.
## What a source did before it was pulled is its own business: a stream
## over a seq hands out work already done, a search's may work only as
## pulled. Combinators make streams from streams: each pull on the
## outermost travels down the chain and pulls one value from the source,
## so a chain is one pass however long it is, and pulls decide how much
## is taken.
##
## Lambdas are written with `=>` and proc types with `->`, both from
## `std/sugar`, which this module exports. Where a combinator's result
## type comes from the lambda (`map`, `flatMap`, `filterMap`), the `it`
## forms (`maps`, `flatMaps`, `filterMaps`) spell nothing; elsewhere a bare
## `x => …` infers its parameter from the combinator.

import std/options
from std/sequtils import toSeq
import std/sugar
export toSeq, sugar

type Stream*[A] = () -> Option[A]

# A generic alias of a proc type, such as `Pred[A] = (A) -> bool`, stops
# `x => …` inferring x, so every signature spells its proc type out.

# ================ constructors ================

template empty*[A](_: typedesc[A]): Stream[A] =
  () => none(A)

proc just*[A](a: A): Stream[A] =
  ## a stream of `a` alone
  var given = false
  () => (block:
    if given: return none A
    given = true
    some a)

proc lazy*[A](make: () -> Stream[A]): Stream[A] =
  ## the stream `make` makes, made only when first pulled
  var s: Stream[A] = nil
  () => (block:
    if s == nil: s = make()
    s())

iterator items*[A](fn: Stream[A]): A =
  var r = fn()
  while r.isSome:
    yield r.get
    r = fn()

iterator pairs*[A](fn: Stream[A]): (int, A) =
  var i = 0
  for each in fn:
    yield (i, each)
    inc i

proc initStream*[A](iter: iterator(): A): Stream[A] =
  () => (block:
    let it = iter()
    if finished(iter): none A else: some it)

template streamOf*(A, body: untyped): untyped =
  initStream(iterator(): A = body)

template streamOf*(body: untyped): untyped =
  initStream(iterator(): auto = body)

template yieldEach*(iter): untyped =
  for each in iter: yield each

proc initStream*[A](arr: sink seq[A]): Stream[A] =
  streamOf A:
    yieldEach arr

proc initStream*[A](arr: openArray[A]): Stream[A] =
  initStream(@arr)

converter toStream*[A](col: openArray[A]): Stream[A] =
  initStream(@col)

proc next*[A](s: Stream[A]): Option[A] =
  s()

# ================ function combinators ================

proc k*[T](v: T): () -> T =
  ## the constant: a proc that always answers `v`
  () => v

proc fold*[A, B](fn: (B, A) -> B, init: B): (A) -> B =
  ## a reducer, answering the accumulator after each value
  var acc = init
  (curr: A) => (block:
    acc = fn(acc, curr)
    acc)

proc scan*[A, B](fn: (B, A) -> B, init: B): (A) -> tuple[prev, curr: B] =
  ## like `fold`, but answers the accumulator from before each value as
  ## well as after
  var acc = init
  (curr: A) => (block:
    let prev = acc
    acc = fn(acc, curr)
    (prev, acc))

proc latch*[A](fn: (A) -> bool): (A) -> bool =
  ## a predicate that, once it has failed, stays failed whatever it is
  ## given
  fold((open: bool, it: A) => open and fn(it), true)

# ================ stream combinators ================

proc map*[A, B](s: Stream[A], fn: (A) -> B): Stream[B] =
  streamOf B:
    for each in s:
      yield fn(each)

proc filter*[A](s: Stream[A], fn: (A) -> bool): Stream[A] =
  streamOf A:
    for each in s:
      if fn(each): yield each

proc filterMap*[A, B](s: Stream[A], fn: (A) -> Option[B]): Stream[B] =
  streamOf B:
    for each in s:
      let r = fn(each)
      if r.isSome: yield r.get

proc tap*[A](s: Stream[A], fn: (A) -> void): Stream[A] =
  ## `s`, calling `fn` on each answer as it is pulled
  streamOf A:
    for each in s:
      fn(each)
      yield each

proc catFrom*[A](streams: Stream[Stream[A]]): Stream[A] =
  ## each stream `streams` hands out, in turn, the next taken only once
  ## the one before has nothing more
  var current: Stream[A] = nil
  () => (block:
    while true:
      if current == nil:
        let next = streams()
        if next.isNone: return none A
        current = next.get
      result = current()
      if result.isSome: return
      current = nil)

proc cat*[A](streams: varargs[Stream[A]]): Stream[A] =
  ## each stream in turn, the next pulled only once the one before has
  ## nothing more: a later stream is never reached past an endless one
  catFrom initStream(@streams)

proc flatMap*[A, B](s: Stream[A], fn: (A) -> Stream[B]): Stream[B] =
  ## each answer's stream from `fn`, in turn
  catFrom s.map(fn)

proc altFrom*[A](streams: () -> Option[Stream[A]]): Stream[A] =
  ## fair turns over the streams that `streams` hands out, admitting one
  ## more at the start of each round, so neither an endless supply of
  ## streams nor one endless stream starves the others
  var
    live: seq[Stream[A]]
    i = 0
    supplyDone = false
  () => (block:
    while true:
      if i >= live.len: # a round is over: admit another
        i = 0
        if not supplyDone:
          let next = streams()
          if next.isSome: live.add next.get
          else: supplyDone = true
        if live.len == 0:
          if supplyDone: return none A
          continue
      result = live[i]()
      if result.isSome:
        inc i
        return
      live.delete(i))

proc alt*[A](streams: varargs[Stream[A]]): Stream[A] =
  ## the streams taking turns: alt(a, b, c) answers from a, b, c, a, b, c
  ## … until all have nothing more
  var
    strms = @streams
    i = 0
    done = false
  () => (block:
    if done: return none A
    for _ in 0 .. strms.high:
      result = strms[i]()
      i = (i + 1) mod strms.len
      if result.isSome: return
    done = true)

proc merge*[A](order: (A, A) -> int, streams: varargs[Stream[A]]): Stream[A] =
  ## streams each already in `order`, merged into one in order; on a tie
  ## the earlier stream goes first. A stream is pulled again only once
  ## its last answer has been taken
  var
    strms = @streams
    heads = newSeq[Option[A]](strms.len)
    stale = toSeq(0 ..< strms.len) # every stream, before the first pull
  () => (block:
    for j in stale: heads[j] = strms[j]()
    stale.setLen 0
    var best = -1
    for j, h in heads:
      if h.isSome and (best < 0 or order(h.get, heads[best].get) < 0):
        best = j
    if best < 0: return none A
    stale.add best
    heads[best])

proc first*[A](s: Stream[A], n: Natural): Stream[A] =
  ## the first `n` answers of `s`, or as many as it has
  streamOf A:
    for _ in 0 ..< n:
      let v = s()
      if v.isNone: break
      yield v.get

# ================ the `it` forms ================
# (their generic is `Item`, not `A`, so a body may speak of its own `A`)

template maps*[Item](s: Stream[Item], body: untyped): untyped =
  s.map((it {.inject.}: Item) => (block: body))

template filters*[Item](s: Stream[Item], body: untyped): untyped =
  s.filter((it {.inject.}: Item) => (block: body))

template filterMaps*[Item](s: Stream[Item], body: untyped): untyped =
  s.filterMap((it {.inject.}: Item) => (block: body))

template flatMaps*[Item](s: Stream[Item], body: untyped): untyped =
  s.flatMap((it {.inject.}: Item) => (block: body))

template taps*[Item](s: Stream[Item], body: untyped): untyped =
  s.tap((it {.inject.}: Item) => (block: body))

# ================ sugar and consumers ================

proc `|`*[A](a, b: Stream[A]): Stream[A] =
  alt(a, b)

proc `&`*[A](a, b: Stream[A]): Stream[A] =
  cat(a, b)

proc exists*[A](s: Stream[A], fn: (A) -> bool): bool =
  ## whether some answer holds for `fn`, pulling no further than the first
  for a in s:
    if fn(a): return true

proc every*[A](s: Stream[A], fn: (A) -> bool): bool =
  ## whether every answer holds for `fn`, pulling no further than the
  ## first that doesn't
  for a in s:
    if not fn(a): return false
  true

proc takeInto*[A](s: Stream[A], col: var openArray[A]): int {.discardable.} =
  ## fills `col` from the front, answering how many it took
  for i, each in s.first(col.len):
    col[i] = each
    result = i + 1

proc take*[A](s: Stream[A], n: Natural): seq[A] =
  ## the first `n` answers of `s` as a seq, or as many as it has
  result = newSeq[A](n)
  result.setLen s.takeInto(result)

when isMainModule:
  import ../core
  proc nums(): Stream[BNum] =
    var i = 0'num
    streamOf:
      while true:
        yield i
        inc i

  echo nums().filters(it mod 2 == 0).first(10).toSeq
