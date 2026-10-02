import std/options

type
  Fold*[A, B] = proc(acc: B, curr: A): B
  Map*[A, B] = proc(it: A): B
  Pred*[A] = Map[A, bool]
  Stream*[A] = proc(): Option[A]
  Oracle*[Q, A] = proc(query: Q): Stream[A]

# ================
# Stream Constructors
# ================

proc initStream*[A](iter: iterator(): A): Stream[A] =
  proc(): auto =
    if finished(iter): return none A
    let r = iter()
    if finished(iter): none A else: some r

proc initStream*[A](arr: seq[A]): Stream[A] =
  var i = 0
  proc(): auto =
    if i >= arr.len: 
      result = none A
    else:
      result = some arr[i]
      inc i

iterator items*(fn: Stream): auto =
  var r = fn()
  while r.isSome:
    yield r.get
    r = fn()

# ================
# Function Combinators
# ================

proc compose*[A, B, C](a: Map[A, B], b: Map[B, C]): Map[A, C] =
  ## Function composition
  proc(it: A): C = it.a.b

proc `&`*[A, B, C](a: Map[A, B], b: Map[B, C]): Map[A, C] =
  ## alias for comp
  compose(a, b)

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

proc split*[A, B, I](fns: array[I, Map[A, B]]): Map[A, array[I, B]] =
  ## Applies an array of functions to produce an array of results
  proc(it: A): auto =
    for i in 0..result.high:
      result[i] = fns[i](it)

type Count[A] = tuple[idx: int, item: A]
proc count*[A](): Map[A, Count[A]] =
  ## Produces a map that includes the
  ## relative order in which a value appeared
  var i = 0
  proc(it: A): auto =
    result = (i, it)
    inc i

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

proc `|>`*[A, B](s: Stream[A], fn: Map[A, B]): auto =
  when B is bool:
    filter(s, fn)
  else:
    map(s, fn)

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

proc cat*[A](streams: varargs[Stream[A]]): Stream[A] =
  ## `cat` produces a new stream that eagerly consumes
  ## from each input stream until it is exhausted before
  ## moving to the next stream.
  ## 
  ## This should only be used with terminating finite streams
  ## and not infinite streams
  var
    strms = @streams
    i = 0
    allDone = false
  proc(): Option[A] =
    if allDone: return none A
    while i <= strms.high:
      result = strms[i]()
      if result.isSome: return
      else: inc i
    allDone = true

# ================
# Sugar
# ================

proc take*[A](self: Stream[A], n: int): seq[A] =
  ## Up to `n` values, pulling no more than that
  result = newSeq[A]()
  while result.len < n:
    let r = self()
    if r.isNone: return
    result.add r.get

proc toSeq*[A](self: Stream[A]): seq[A] =
  result = newSeq[A]()
  for each in self:
    result.add each
