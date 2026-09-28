import std/strformat
import fusion/matching
import ../[core, ops]

type
  MergeResultKind* = enum
    ## Describes the 4 possible outcomes of a semi-lattice merge
    ## Let c = merge(a, b) we can describe the outcomes
    ## Same:
    ## c == a
    ## c == b
    ## Absorbed:
    ## c == a
    ## c != b
    ## Replaced:
    ## c != a
    ## c == b
    ## Joined:
    ## c != a
    ## c != b
    moAbsorbed, moSame, moReplaced, moJoined

  Merge*[T] = object
    value*: T
    kind*: MergeResultKind

  Contradiction*[T] = object of CatchableError
    ## raised when two values in a lattice are mutually exclusive
    prev*, curr*: T

  Lattice* = concept x, y, type T
    T.bottom is T
    merge(x, y) is Merge[T]

  ValueLike* = concept x, type T
    x.toValue() is Value
    T.fromValue(Value) is T

  ValueLattice* = ValueLike and Lattice

func didGain*(self: MergeResultKind): bool =
  self in {moReplaced, moJoined}

func kept*(self: MergeResultKind): bool =
  not self.didGain

func didGain*(self: Merge): bool =
  self.kind.didGain

func kept*(self: Merge): bool =
  self.kind.kept

func `or`*(a, b: Merge): Merge =
  if a.didGain: a else: b

func apply*(self: Merge, prev: var self.T): bool =
  if self.didGain:
    prev = self.value
    return true

template settle*(prev, curr, body) {.dirty.} =
  template same =
    return Merge[typeof prev](value: prev, kind: moSame)
  template absorbed =
    return Merge[typeof prev](value: prev, kind: moAbsorbed)
  template replaced =
    return Merge[typeof curr](value: curr, kind: moReplaced)
  template joined(joinBody) =
    let built = block:
      joinBody
    return Merge[typeof built](value: built, kind: moJoined)
  template contradiction(msg: string) =
    contradiction(prev, curr, msg)
  body

template productMerge*(T: typedesc) =
  func bottom*(_: type T): T =
    for f in fields(result):
      f = typeof(f).bottom
  proc merge*(prev, curr: T): Merge[T] =
    mixin merge
    var
      value = prev
      outcome = moSame
    for a, b in fields(value, curr):
      let m = merge(a, b)
      outcome = max(outcome, m.kind)
      a = m.value
    Merge[T](value: value, kind: outcome)

proc contradiction*[T](prev, curr: T, msg: string) {.noreturn.} =
  when compiles($prev):
    let m = fmt"contradiction! {msg} prev: {prev} curr: {curr}"
    var e = newException(Contradiction[T], m)
    e.prev = prev
    e.curr = curr
    raise e
  else:
    var e = newException(Contradiction[T], "contradiction! " & msg)
    e.prev = prev
    e.curr = curr
    raise e

proc compare*[T](prev, curr: T): MergeResultKind =
  mixin merge
  merge(prev, curr).outcome

proc `<=`*[T: Lattice](a, b: T): bool =
  mixin merge
  merge(a, b).didGain

proc add*[T: Lattice](prev: var T, curr: T) =
  mixin merge
  let outcome = merge(prev, curr)
  if outcome.didGain:
    prev = outcome.value

proc add*[T: ValueLattice](prev: var T, curr: Value) =
  mixin fromValue
  prev &= fromValue(T, curr)

proc fromValue*[A, B: ValueLattice](_: type (A, B), a, b: Value): (A, B) =
  (A.fromValue(a), B.fromValue(b))

proc fromValue*[T: ValueLattice](a, b: Value): (T, T) =
  (T, T).fromValue(a, b)

# ================ Min / Max ================

type
  Min* = distinct int
  Max* = distinct int

converter toMin*(n: int): Min = Min(n)
converter toMax*(n: int): Max = Max(n)

func bottom*(_: type Min): Min = int.high
func bottom*(_: type Max): Max = int.low

proc merge*(prev, curr: Min): Merge[Min] =
  settle(prev, curr):
    if prev.int <= curr.int:
      absorbed
    replaced

proc merge*(prev, curr: Max): Merge[Max] =
  settle(prev, curr):
    if prev.int >= curr.int:
      absorbed
    replaced


## ================ Numeric Refinement Lattice ================

type
  NumKind = enum
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

func `==`*(a, b: Numeric): bool =
  case (a, b)
  of (Bottom(), Bottom()):
    return true
  of (Interval(), Interval()):
    return a.lo == b.lo and a.hi == b.hi
  of (Scalar(), Scalar()):
    return a.n == b.n

proc merge*(previous, current: Numeric): Merge[Numeric] =
  let
    prev = previous.normalize
    curr = current.normalize
  settle(prev, curr):
    if prev == curr:
      same
    case (prev, curr)
    of (_, Bottom()):
      absorbed
    of (Bottom(), _):
      replaced
    of (Interval(lo: @lo, hi: @hi), Scalar(n: @n)):
      if n notin lo..hi:
        contradiction "scalar outside interval"
      replaced
    of (Scalar(n: @n), Interval(lo: @lo, hi: @hi)):
      if n notin lo..hi:
        contradiction "scalar outside interval"
      absorbed
    of (Scalar(n: @x), Scalar(n: @y)):
      if x != y:
        contradiction "not equal"
      absorbed
    of (Interval(lo: @lo1, hi: @hi1), Interval(lo: @lo2, hi: @hi2)):
      let
        lo = max(lo1, lo2)
        hi = min(hi1, hi2)
        changed = (lo1 != lo) or (hi1 != hi)
      if lo > hi:
        contradiction "disjoint intervals"
      if changed:
        joined:
          interval(lo, hi).normalize
      else:
        absorbed
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

proc `<=`*(a, b: Numeric): bool =
  ## `b` refines `a`: bottom is below everything, a range is below
  ## every range inside it, a scalar is below only itself
  let (x, y) = (a.normalize, b.normalize)
  if x.kind == nkBottom: return true
  if y.kind == nkBottom: return false
  let
    (lo1, hi1) = x.bounds
    (lo2, hi2) = y.bounds
  lo1 <= lo2 and hi2 <= hi1

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

# ================ Exact ================

type
  Exact* = object
    value*: Value

func bottom*(_: type Exact): Exact =
  Exact(value: null())

proc merge*(prev, curr: Exact): Merge[Exact] =
  settle(prev, curr):
    if curr.value == null():
      absorbed
    elif prev.value == null():
      replaced
    elif prev.value == curr.value:
      same
    else:
      contradiction "not equal"

func toValue*(self: Exact): Value =
  self.value

func fromValue*(_: type Exact, val: Value): Exact =
  Exact(value: val)

proc `$`*(self: Exact): string =
  $self.value

# ================ Set / BTree Union ================

func bottom*(_: type BSet): BSet =
  newBSet()

func bottom*(_: type BDict): BDict =
  newBDict()

proc merge*(prev, curr: BSet): Merge[BSet] =
  settle(prev, curr):
    if curr <= prev:
      absorbed
    joined:
      prev + curr

proc merge*(prev, curr: BDict): Merge[BDict] =
  settle(prev, curr):
    if curr <= prev:
      absorbed
    elif prev.disjoint(curr):
      joined prev + curr
    else:
      contradiction "conflicting dictionaries"

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

proc merge*[T](prev, curr: Versioned[T]): Merge[Versioned[T]] =
  settle(prev, curr):
    if prev == curr or
        prev.version > curr.version:
      absorbed
  if prev.version < curr.version:
    replaced
  contradiction "version issue"

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

  for i, v in vals.items:
    try:
      let n = Numeric.fromValue(v)
      foo &= n
      vers &= n.initVersion(i)
      echo foo
    except Contradiction[Numeric] as e:
      echo e.msg

  var exact: Exact

  exact &= rv"foo"

  echo exact

  type
    Something = object
      a: Max
      b: Min

  proc `$`*(self: Something): string =
    let s = (self.a.int)..(self.b.int)
    $s

  productMerge Something

  var
    a = Something(a: 10, b: 18)
    b = Something(a: 15, b: 25)
    c = merge(a, b)

  echo a
  echo b
  echo c

  echo c.apply(a)

  echo a
