import std/strformat
import fusion/matching
import ./[core, ops]

type
  Merged*[T] = tuple
    value: T
    changed: bool

  Lattice* = concept x, y, type T
    # TODO: I should add a better order operation here
    # but I haven't found something that's ergonomic & performant
    T.bottom is T
    x == y is bool
    merge(x, y) is Merged[T]
  Contradiction*[T] = object of CatchableError
    ## raised when two values in a lattice are mutually exclusive
    prev*, curr*: T    
  ValueLike* = concept x, type T
    x.toValue() is Value
    T.fromValue(Value) is T
  ValueLattice* = ValueLike and Lattice

proc contradiction*[T](prev, curr: T, msg: string) {.noreturn.} =
  when compiles($prev):
    let m = fmt"contradiction! {msg} prev: {prev} curr: {curr}"
    var e = newException(Contradiction[T], m)
    e.prev = prev
    e.curr = curr
    raise e
  else:
    var e = newException(Contradicion[T], "contradiction! " & msg)
    e.prev = prev
    e.curr = curr
    raise e

proc `add`*[T: Lattice](prev: var T, curr: T) =
  mixin merge
  let (update, changed) = merge(prev, curr)
  if changed:
    prev = update

## ================ Numeric Refinement Lattice ================

type
  NumKind = enum
    nkBottom, nkInterval, nkScalar

  Numeric* = object
    case kind: NumKind
    of nkBottom: discard
    of nkInterval:
      lo*, hi*: int
    of nkScalar:
      n*: int

Numeric.refuseWith ValueError

proc scalar*(n: int): Numeric =
  Numeric(kind: nkScalar, n: n)

proc interval*(lo, hi: int): Numeric =
  if lo <= hi:
    Numeric(kind: nkInterval, lo: lo, hi: hi)
  else:
    Numeric(kind: nkInterval, lo: hi, hi: lo)

converter toNumeric*(n: int): Numeric =
  scalar n

converter toNumeric*(n: Slice[int]): Numeric =
  interval(n.a, n.b)

func `$`*(self: Numeric): string =
  case self
  of Bottom():
    return "nothing"
  of Interval(lo: @lo, hi: @hi):
    return fmt"{lo}..{hi}"
  of Scalar(n: @n):
    return $n

func bottom*(_: type Numeric): Numeric =
  Numeric(kind: nkBottom)

proc `==`*(a,b: Numeric): bool =
  case (a, b)
  of (Scalar(), Scalar()):
    a.n == b.n
  of (Interval(), Interval()):
    (a.lo == b.lo) and (a.hi == b.hi)
  of (Bottom(), Bottom()):
    true
  else:
    false

proc merge*(prev, curr: Numeric): Merged[Numeric] =
  if prev == curr: 
    return (prev, false)
  case (prev, curr)
  of (_, Bottom()):
    return (prev, false)
  of (Bottom(), _):
    return (curr, true)
  of (Scalar(n: @n), Interval(lo: @lo, hi: @hi)) |
      (Interval(lo: @lo, hi: @hi), Scalar(n: @n)):
    if n notin lo..hi:
      contradiction[Numeric](prev, curr, "scalar outside interval")
    return (scalar n, true)
  of (Scalar(n: @x), Scalar(n: @y)):
    if x != y:
      contradiction[Numeric](prev, curr, "not equal")
    return (prev, false)
  of (Interval(lo: @lo1, hi: @hi1), Interval(lo: @lo2, hi: @hi2)):
    let
      lo = max(lo1, lo2)
      hi = min(hi1, hi2)
    if lo > hi:
      contradiction[Numeric](prev, curr, "disjoint intervals")
    if lo == hi:
      return (scalar lo, true)
    
    let changed = (lo1 != lo) or (hi1 != hi)
    return (interval(lo, hi), changed)
  refuse Numeric, "should never get here"

func toValue*(self: Numeric): Value =
  case self
  of Bottom():
    return null()
  of Interval(lo: @lo, hi: @hi):
    return initList(@[num(lo), num(hi)])
  of Scalar(n: @n):
    return num(n)

proc toNumeric(val: Value): Numeric =
  case val
  of Num(num.toInt: @i) |
      List(mark: false, [(mark: false, num.toInt: @i), (mark: false, num.toInt:(it == i))]):
    scalar i
  of List(mark: false, [(mark: false, num.toInt: @lo), (mark: false, num.toInt: @hi(it >= lo))]):
    interval lo, hi
  else:
    Numeric(kind: nkBottom)

proc fromValue*(_: type Numeric, val: Value): Numeric =
  toNumeric val

template numericBinaryOp(op) =
  proc op*(l, r: Numeric): auto =
    case (l, r)
    of (Scalar(n: @n), Interval(lo: @lo, hi: @hi)):
      interval op(n, lo), op(n, hi)
    of (Interval(lo: @lo, hi: @hi), Scalar(n: @n)):
      interval op(lo, n), op(hi, n)
    of (Scalar(n: @a), Scalar(n: @b)):
      scalar op(a, b)
    of (Interval(lo: @lo1, hi: @hi1), Interval(lo: @lo2, hi: @hi2)):
      interval op(lo1, lo2), op(hi1, hi2)
    else:
      Numeric.bottom

numericBinaryOp `+`
numericBinaryOp `-`
numericBinaryOp `*`
numericBinaryOp `div`
numericBinaryOp `mod`

# ================ Set / BTree Union ================

func bottom*(_: type BSet): BSet =
  newBSet()

func bottom*(_: type BDict): BDict =
  newBDict()

proc merge*(prev, curr: BSet): Merged[BSet] =
  if prev <= curr:
    return (prev, false)
  (prev + curr, true)

proc merge*(prev, curr: BDict): Merged[BDict] =
  if prev <= curr:
    return (prev, false)
  (prev + curr, true)

# ================ Min / Max ================

type
  Min* = distinct int
  Max* = distinct int

converter toMin*(n: int): Min =
  Min(n)
converter toMax*(n: int): Max =
  Max(n)

func `==`*(a,b: Min): bool {.borrow.}
func `==`*(a,b: Max): bool {.borrow.}

func bottom*(_: type Min): Min =
  int.high

func bottom*(_: type Max): Max =
  int.low

proc merge*(prev, curr: Min): Min =
  min(prev.int, curr.int)

proc merge*(prev, curr: Max): Max =
  max(prev.int, curr.int)

# ================ Versioned ================

type
  Versioned*[T] = object
    version*: Natural
    value*: T

proc initVersion*[T](self: T, version = 1): Versioned[T] =
  Versioned[T](version: version, value: self)

proc bottom*[T](_: type Versioned[T]): Versioned[T] =
  when T is Lattice:
    initVersion(T.bottom, 0)
  else:
    initVersion(T.default, 0)

proc `==`[T](prev, curr: Versioned[T]): bool =
  (prev.version == curr.version) and (prev.value == curr.value)

proc merge*[T](prev, curr: Versioned[T]): Merged[Versioned[T]] =
  if prev == curr or 
      prev.version > curr.version:
    return (prev, false)
  if prev.version < curr.version:
    return (curr, true)
  when T is Lattice:
    let (update, changed) = merge(prev.value, curr.value)
    if not changed:
      return (prev, false)
    let v = max(prev.version, curr.version)
    (initVersion(update, v + 1), true)
  else:
    contradiction(prev, curr, "version issue")

when isMainModule:
  let vals = rv"""[
    "hello"
    (10 20)
    [10 20]
    [15 69]
    [8 15]
    {1 2}
    18
  ]"""

  var
    foo: Numeric
    vers: Versioned[Numeric]

  for v in vals.items:
    try:
      let n = Numeric.fromValue(v)
      foo &= n
      vers &= n.initVersion
      echo foo
    except Contradiction[Numeric] as e:
      echo e.msg