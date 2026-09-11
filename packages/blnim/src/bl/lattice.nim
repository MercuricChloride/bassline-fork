from std/strformat import fmt
import fusion/matching
import ./[core, ops]

type
  Lattice = concept x, y, type T
    T.bottom is T
    merge(x, y) is T
  Contradiction[T] = object of CatchableError
    ## raised when two values in a lattice are mutually exclusive
    prev*, curr*: T    
  ValueLike = concept x, type T
    x.toValue() is Value
    T.fromValue(Value) is T
  StringLike = concept x
    $x is string
  ValueLattice* = ValueLike and Lattice

proc contradiction*[T: Lattice](prev, curr: T, msg: string) {.noreturn.} =
  when T is StringLike:
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

proc `+=`*[T: Lattice](prev: var T, curr: T) =
  mixin merge
  prev = merge(prev, curr)

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
  Numeric(kind: nkInterval, lo: lo, hi: hi)

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

proc merge*(prev, curr: Numeric): Numeric =
  case (prev, curr)
  of (Bottom(), @other) |
      (@other, Bottom()):
    return other
  of (Scalar(n: @n), Interval(lo: @lo, hi: @hi)) |
      (Interval(lo: @lo, hi: @hi), Scalar(n: @n)):
    if n notin lo..hi:
      contradiction[Numeric](prev, curr, "scalar outside interval")
    return scalar n
  of (Scalar(n: @x), Scalar(n: @y)):
    if x != y:
      contradiction[Numeric](prev, curr, "not equal")
    return prev
  of (Interval(lo: @lo1, hi: @hi1), Interval(lo: @lo2, hi: @hi2)):
    let
      lo = max(lo1, lo2)
      hi = min(hi1, hi2)
    if lo > hi:
      contradiction[Numeric](prev, curr, "disjoint intervals")
    if lo == hi:
      return scalar lo
    return interval(lo, hi)
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

# ================ Set / BTree Union ================

func bottom*(_: type BSet): BSet =
  newBSet()

func bottom*(_: type BDict): BDict =
  newBDict()

proc merge*(prev, curr: BSet): BSet =
  prev + curr

proc merge*(prev, curr: BDict): BDict =
  prev + curr

# ================ Min / Max ================

type
  Min* = distinct int
  Max* = distinct int

func bottom*(_: type Min): Min =
  Min(int.high)

func bottom*(_: type Max): Max =
  Max(int.low)

proc merge*(prev, curr: Max): Max =
  Max max(prev.int, curr.int)

proc merge*(prev, curr: Min): Min =
  Min min(prev.int, curr.int)

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

proc merge*[T](prev, curr: Versioned[T]): Versioned[T] =
  ((version: @p, value: @pv), (version: @c, value: @cv)) := (prev, curr)
  if p < c:
    return curr
  if p > c:
    return prev
  when T is Lattice:
    Versioned[T](version: p, value: pv.merge(cv))
  else:
    contradiction(prev, curr, "version issue")

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
    foo += n
    vers += n.initVersion
    echo foo
  except Contradiction[Numeric] as e:
    echo e.msg