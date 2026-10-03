import std/options

type
  Fold*[A, B] = proc(acc: B, curr: A): B
  Map*[A, B] = proc(it: A): B
  Stream*[A] = proc(): Option[A]
  Pred*[A] = Map[A, bool]

template `->`*(T, body): untyped =
  proc(it{.inject.}: T): auto = body

# ================
# Stream Constructors
# ================

proc empty*[A](): Stream[A] =
  proc(): Option[A] = none A

proc just*[A](a: A): Stream[A] =
  ## a stream of `a` alone
  var given = false
  proc(): auto =
    if given: return none A
    given = true
    some a

proc lazy*[A](make: proc(): Stream[A]): Stream[A] =
  ## the stream `make` makes, made only when first pulled
  var s: Stream[A] = nil
  proc(): auto =
    if s == nil: s = make()
    s()

proc initStream*[A](arr: seq[A]): Stream[A] =
  var i = 0
  proc(): auto =
    if i >= arr.len: 
      result = none A
    else:
      result = some arr[i]
      inc i

proc `[]`*[A](s: Stream[A]): Option[A] =
  ## the next answer, for a consumer that wants just one: the pull itself
  s()

iterator items*(fn: Stream): auto =
  var r = fn()
  while r.isSome:
    yield r.get
    r = fn()

# ================
# Function Combinators
# ================

proc k*[T](v: T): proc(): T =
  ## the constant: a proc that always answers `v`
  proc(): T = v

proc fold*[A, B](fn: Fold[A, B], init: B): Map[A, B] =
  ## A reducer
  var acc = init
  proc(curr: A): B =
    acc = fn(acc, curr)
    acc

proc scan*[A, B](fn: Fold[A, B], init: B): Map[A, tuple[prev, curr: B]] =
  ## Like `fold`, but answers the accumulator from before each
  ## value as well as after
  var acc = init
  proc(curr: A): tuple[prev, curr: B] =
    let prev = acc
    acc = fn(acc, curr)
    (prev, acc)

proc latch*[A](fn: Pred[A]): Pred[A] =
  ## Latch is like a normal predicate, but upon failing
  ## it will short circuit to false ignoring the provided
  ## values.
  proc f(open: bool, curr: A): bool =
    open and fn(curr)
  fold(f, true)

# ================
# Stream Combinators
# ================

proc map*[A, B](s: Stream[A], fn: Map[A, B]): Stream[B] =
  ## Applies `fn` to each value in the stream
  proc (): Option[B] = s().map(fn)

proc filter*[A](s: Stream[A], fn: Pred[A]): Stream[A] =
  ## The values `fn` accepts. The others are pulled past.
  proc(): Option[A] =
    result = s()
    while result.isSome and not fn(result.get):
      result = s()

proc alt*[A](streams: varargs[Stream[A]]): Stream[A] =
  ## `alt` produces a new stream that fairly takes
  ## values from the input streams.
  ## If called like: alt(a, b, c)
  ## it will produce a, b, c, a, b, c until
  ## they are all exhausted.
  var
    strms = @streams
    i = 0
    done = false
  proc next(): auto =
    result = strms[i]()
    i = (i + 1) mod strms.len
  proc(): Option[A] =
    if done: return none A
    for _ in 0..strms.high:
      # we want to check every stream
      result = next()
      if result.isSome: return
    done = true

proc catFrom*[A](streams: proc(): Option[Stream[A]]): Stream[A] =
  ## each stream `streams` hands out, in turn, the next taken only once
  ## the one before has nothing more
  var current: Stream[A] = nil
  proc(): Option[A] =
    while true:
      if current == nil:
        let next = streams()
        if next.isNone: return none A
        current = next.get
      result = current()
      if result.isSome: return
      current = nil

proc cat*[A](streams: varargs[Stream[A]]): Stream[A] =
  ## each stream in turn, the next pulled only once the one before has
  ## nothing more: a later stream is never reached past an endless one
  catFrom(initStream(@streams))

proc flatMap*[A, B](s: Stream[A], fn: proc(a: A): Stream[B]): Stream[B] =
  ## each answer's stream from `fn`, in turn
  catFrom(s.map(fn))

proc filterMap*[A, B](s: Stream[A], fn: proc(a: A): Option[B]): Stream[B] =
  ## what `fn` makes of each answer, passing over those it makes nothing of
  proc(): Option[B] =
    while true:
      let a = s()
      if a.isNone: return none B
      result = fn(a.get)
      if result.isSome: return

proc tap*[A](s: Stream[A], fn: proc(a: A)): Stream[A] =
  ## `s`, calling `fn` on each answer as it is pulled
  proc(): Option[A] =
    result = s()
    if result.isSome: fn(result.get)

proc altFrom*[A](streams: proc(): Option[Stream[A]]): Stream[A] =
  ## fair turns over the streams that `streams` hands out, admitting one
  ## more at the start of each round, so neither an endless supply of
  ## streams nor one endless stream starves the others
  var
    live: seq[Stream[A]]
    i = 0
    supplyDone = false
  proc(): Option[A] =
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
      live.delete(i)

proc merge*[A](order: proc(a, b: A): int, streams: varargs[Stream[A]]):
    Stream[A] =
  ## streams each already in `order`, merged into one in order; on a tie
  ## the earlier stream goes first. A stream is pulled again only once
  ## its last answer has been taken
  var
    strms = @streams
    heads = newSeq[Option[A]](strms.len)
    stale = newSeq[int](strms.len) # every stream, before the first pull
  for j in 0 ..< strms.len: stale[j] = j
  proc(): Option[A] =
    for j in stale: heads[j] = strms[j]()
    stale.setLen(0)
    var best = -1
    for j, h in heads:
      if h.isSome and (best < 0 or order(h.get, heads[best].get) < 0):
        best = j
    if best < 0: return none A
    stale.add best
    heads[best]

# ================
# Sugar
# ================

proc `|>`*[A, B](s: Stream[A], fn: Map[A, B]): auto =
  when B is bool:
    filter(s, fn)
  else:
    map(s, fn)

proc `|`*[A](a, b: Stream[A]): auto =
  alt(a, b)

proc `&`*[A](a, b: Stream[A]): auto =
  cat(a, b)

proc exists*[A](s: Stream[A], fn: Pred[A]): bool =
  ## whether some answer holds for `fn`, pulling no further than the first
  for a in s:
    if fn(a): return true

proc every*[A](s: Stream[A], fn: Pred[A]): bool =
  ## whether every answer holds for `fn`, pulling no further than the
  ## first that doesn't
  for a in s:
    if not fn(a): return false
  true

proc take*[A](self: Stream[A], n: Natural): seq[A] =
  ## Up to `n` values, pulling no more than that
  result = newSeq[A]()
  while result.len < n:
    let r = self()
    if r.isNone: return
    result.add r.get

proc collect*[A](self: Stream[A]): seq[A] =
  ## every answer, pulled until the stream has nothing more
  result = newSeq[A]()
  for each in self:
    result.add each