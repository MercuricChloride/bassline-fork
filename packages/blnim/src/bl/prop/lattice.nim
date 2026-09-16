import std/strformat
import fusion/matching
import ../[core, ops]

type
  Merged*[T] = tuple
    value: T
    changed: bool
  
  Contradiction*[T] = object of CatchableError
    ## raised when two values in a lattice are mutually exclusive
    prev*, curr*: T

  Lattice* = concept x, y, type T
    # TODO: I should add a better order operation here
    # but I haven't found something that's ergonomic & performant
    T.bottom is T
    x == y is bool
    merge(x, y) is Merged[T]
  
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

proc add*[T: Lattice](prev: var T, curr: T) =
  mixin merge
  let (update, changed) = merge(prev, curr)
  if changed:
    prev = update

proc add*[T: ValueLattice](prev: var T, curr: Value) =
  prev &= T.fromValue(curr)

proc fromValue*[A, B: ValueLattice](_: type (A, B), a, b: Value): (A, B) =
  (A.fromValue(a), B.fromValue(b))

proc fromValue*[T: ValueLattice](a, b: Value): (T, T) =
  (T, T).fromValue(a, b)

## ================ Numeric Refinement Lattice ================

type
  NumKind* = enum
    nkBottom, nkInterval, nkScalar

  Numeric* = object
    case kind*: NumKind
    of nkBottom: discard
    of nkInterval:
      lo*, hi*: int
    of nkScalar:
      n*: int

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

func normalize*(self: Numeric): Numeric =
  case self
  of Interval(lo: @lo, hi: @hi):
    if lo == hi:
      return scalar lo
  self

proc `==`*(a,b: Numeric): bool =
  case (a.normalize, b.normalize)
  of (Scalar(), Scalar()):
    a.n == b.n
  of (Interval(), Interval()):
    (a.lo == b.lo) and (a.hi == b.hi)
  of (Bottom(), Bottom()):
    true
  else:
    false

proc merge*(previous, current: Numeric): Merged[Numeric] =
  let
    prev = previous.normalize
    curr = current.normalize
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
    return (scalar n, prev.kind != nkScalar)
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
  raise newException(ValueError, "should never get here")

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
    Numeric.bottom

proc fromValue*(_: type Numeric, val: Value): Numeric =
  toNumeric(val)

func bounds*(self: Numeric): (int, int) =
  ## a scalar is the range holding only it
  case self
  of Scalar(n: @n):
    return (n, n)
  of Interval(lo: @lo, hi: @hi):
    return (lo, hi)
  else:
    raise newException(ValueError, "bottom has no bounds")

func hull(a, b: Numeric): Numeric =
  ## the narrowest range holding both; bottom holds nothing
  if a.kind == nkBottom: return b
  if b.kind == nkBottom: return a
  let
    (lo1, hi1) = a.bounds
    (lo2, hi2) = b.bounds
  interval(min(lo1, lo2), max(hi1, hi2)).normalize

template corners(a, b, c, d: int, op): Numeric =
  ## the range of `op` over `a..b` and `c..d` where `op` is monotone in
  ## each argument: its bounds are among the four corners
  let xs = [op(a, c), op(a, d), op(b, c), op(b, d)]
  interval(min(xs), max(xs)).normalize

template numericBinaryOp(op) =
  proc op*(l, r: Numeric): Numeric =
    ## `+`, `-` and `*` are monotone in each argument everywhere
    if l.kind == nkBottom or r.kind == nkBottom:
      return Numeric.bottom
    let
      (a, b) = l.bounds
      (c, d) = r.bounds
    corners(a, b, c, d, op)

numericBinaryOp `+`
numericBinaryOp `-`
numericBinaryOp `*`

proc `div`*(l, r: Numeric): Numeric =
  ## Truncating division over ranges. `div` is monotone in each argument
  ## on either side of zero, so the divisor range is split there and each
  ## side takes its corners. Zero divides nothing, so a divisor range
  ## that is only zero yields bottom.
  if l.kind == nkBottom or r.kind == nkBottom:
    return Numeric.bottom
  let
    (a, b) = l.bounds
    (c, d) = r.bounds
  result = Numeric.bottom
  if d >= 1:
    result = hull(result, corners(a, b, max(c, 1), d, `div`))
  if c <= -1:
    result = hull(result, corners(a, b, c, min(d, -1), `div`))

proc `mod`*(l, r: Numeric): Numeric =
  ## Remainder over ranges. A remainder takes the dividend's sign and a
  ## magnitude below both the dividend's and the divisor's, so the result
  ## lies within the dividend's range clamped by the largest divisor
  ## magnitude. When every dividend is smaller than every divisor, the
  ## dividend passes through unchanged.
  if l.kind == nkBottom or r.kind == nkBottom:
    return Numeric.bottom
  let
    (a, b) = l.bounds
    (c, d) = r.bounds
  if c == 0 and d == 0:
    return Numeric.bottom
  let
    most = max(abs c, abs d)
    least = if c <= 0 and d >= 0: 1 else: min(abs c, abs d)
  if a >= 0:
    if b < least: l.normalize
    else: interval(0, min(b, most - 1)).normalize
  elif b <= 0:
    if -a < least: l.normalize
    else: interval(max(a, 1 - most), 0).normalize
  else:
    interval(max(a, 1 - most), min(b, most - 1)).normalize

# ================ Set / BTree Union ================

func bottom*(_: type BSet): BSet =
  newBSet()

func bottom*(_: type BDict): BDict =
  newBDict()

proc merge*(prev, curr: BSet): Merged[BSet] =
  if curr <= prev:
    return (prev, false)
  (prev + curr, true)

proc merge*(prev, curr: BDict): Merged[BDict] =
  if curr <= prev:
    return (prev, false)
  (prev + curr, true)

func toBSet(val: Value): BSet =
  case val
  of Set(els: @els):
    els
  else:
    BSet.bottom

func toBDict(val: Value): BDict =
  case val
  of (dict: @dict):
    dict
  else:
    BDict.bottom

func fromValue*(_: type BSet, val: Value): BSet =
  toBSet val

func fromValue*(_: type BDict, val: Value): BDict =
  toBDict val

# ================ Min / Max ================

type
  Min* = distinct int
  Max* = distinct int

converter toMin*(n: int): Min = Min(n)
converter toMax*(n: int): Max = Max(n)

func `==`*(a,b: Min): bool {.borrow.}
func `==`*(a,b: Max): bool {.borrow.}

func bottom*(_: type Min): Min =
  int.high

func bottom*(_: type Max): Max =
  int.low

proc merge*(prev, curr: Min): Merged[Min] =
  if prev.int <= curr.int:
    return (prev, false)
  return (curr.int, true)

proc merge*(prev, curr: Max): Merged[Max] =
  if prev.int >= curr.int:
    return (prev, false)
  return (curr.int, true)

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

let versionShape = rv"(shape (version v value) {v value})"

proc value*(self: Versioned): self.T =
  self.value

proc version*(self: Versioned): Natural =
  self.version

proc fromValue*[T: ValueLike](
    _: type Versioned[T], val: Value): Versioned[T] =
  var bindings = extract(versionShape, val)

  if bindings.len == 0 or
      bindings["v"].kind != bNum:
    return bottom(Versioned[T])
  let
    version = bindings["v"].num.toInt
    value = T.fromValue(bindings["value"])
  Versioned[T](version: version, value: value)

proc toValue*(self: Versioned): Value =
  mixin toValue
  var bindings = initDict()
  bindings["v"] = num self.version
  bindings["value"] = toValue(self.value)
  inject(versionShape, bindings)

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