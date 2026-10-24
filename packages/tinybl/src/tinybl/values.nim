import std/algorithm
import ./[ce, text]

refuseWith BasslineError

# ================
# Sorted Table
# ================

type
  Entry*[K, V] = tuple[key: K, val: V]
  Pair*[T] = Entry[T, T]
  SortedTable*[K, V] = object
    keys: seq[K]
    vals: seq[V]

func keys*[K, V](self: SortedTable[K, V]): lent seq[K] =
  self.keys

func vals*[K, V](self: SortedTable[K, V]): lent seq[V] =
  self.vals

func toSortedTable*[K, V](
    keys: sink seq[K], vals: sink seq[V], sorted = false
): SortedTable[K, V] =
  mixin cmp
  guard keys.len == vals.len, "a value for every key"
  if sorted:
    return SortedTable[K, V](keys: keys, vals: vals)
  var
    ks = keys
    vs = vals
    order = newSeq[int](ks.len)
  for i in 0 ..< order.len:
    order[i] = i
  order.sort(
    proc(a, b: int): int =
      cmp(ks[a], ks[b])
  )
  result.keys = newSeqOfCap[K](ks.len)
  result.vals = newSeqOfCap[V](vs.len)
  for i in order:
    result.keys.add move(ks[i])
    result.vals.add move(vs[i])

func toSortedTable*[K, V](
    self: openArray[Entry[K, V]], sorted = false
): SortedTable[K, V] =
  var
    keys = newSeqOfCap[K](self.len)
    vals = newSeqOfCap[V](self.len)
  for e in self:
    keys.add e.key
    vals.add e.val
  toSortedTable(move keys, move vals, sorted)

func lowerIdx[K, V](self: SortedTable[K, V], key: K): int =
  ## the first index whose key is not below key
  mixin cmp
  self.keys.lowerBound(key, cmp)

func indexOf*[K, V](self: SortedTable[K, V], key: K): int =
  ## key's index, or -1 when it has none
  mixin cmp
  let i = self.lowerIdx(key)
  if i < self.keys.len and cmp(self.keys[i], key) == 0: i else: -1

func put*[K, V](self: var SortedTable[K, V], key: sink K, val: sink V) =
  mixin cmp
  let i = self.lowerIdx(key)
  if i < self.keys.len and cmp(self.keys[i], key) == 0:
    self.vals[i] = val
  else:
    self.keys.insert(key, i)
    self.vals.insert(val, i)

func delete*[K, V](self: var SortedTable[K, V], key: K) =
  let i = self.indexOf(key)
  if i != -1:
    self.keys.delete(i)
    self.vals.delete(i)

func get*[K, V](self: SortedTable[K, V], key: K): lent V =
  let i = self.indexOf(key)
  if i == -1:
    raise newException(KeyError, "key not found")
  self.vals[i]

func len*[K, V](self: SortedTable[K, V]): Natural =
  self.keys.len

func low*[K, V](self: SortedTable[K, V]): lent K =
  self.keys[0]

func high*[K, V](self: SortedTable[K, V]): lent K =
  self.keys[self.keys.len - 1]

# ================
# Table Sugar
# ================

func getOrPut*[K, V](self: var SortedTable[K, V], key: K, val: sink V): lent V =
  mixin cmp
  let i = self.lowerIdx(key)
  if i == self.keys.len or cmp(self.keys[i], key) != 0:
    self.keys.insert(key, i)
    self.vals.insert(val, i)
  self.vals[i]

func getOr*[K, V](self: SortedTable[K, V], key: K, val: V): V =
  let i = self.indexOf(key)
  if i == -1:
    val
  else:
    self.vals[i]

func contains*[K, V](self: SortedTable[K, V], key: K): bool =
  self.indexOf(key) != -1

iterator items*[K, V](self: SortedTable[K, V]): lent V =
  for v in self.vals:
    yield v

iterator pairs*[K, V](self: SortedTable[K, V]): Entry[lent K, lent V] =
  for i in 0 ..< self.keys.len:
    yield (self.keys[i], self.vals[i])

func `[]`*[K, V](self: SortedTable[K, V], key: K): lent V =
  self.get(key)

func `[]`*[K, V](self: var SortedTable[K, V], key: K): var V =
  let i = self.indexOf(key)
  if i == -1:
    raise newException(KeyError, "key not found")
  self.vals[i]

func `[]=`*[K, V](self: var SortedTable[K, V], key: sink K, val: sink V) =
  self.put(key, val)

# ================
# Sorted Set
# ================

type SortedSet*[T] {.byref.} = object
  data: seq[T]

func toSortedSet*[T](self: openArray[T], sorted = false): SortedSet[T] =
  mixin cmp
  result.data = @self
  if not sorted:
    result.data.sort(cmp)

func toSortedSet*[T](self: sink seq[T], sorted = false): SortedSet[T] =
  mixin cmp
  result.data = self
  if not sorted:
    result.data.sort(cmp)

func data*[T](self: SortedSet[T]): lent seq[T] =
  self.data

func lowerIdx[T](self: SortedSet[T], val: T): int =
  ## the first index whose member is not below val
  mixin cmp
  self.data.lowerBound(val, cmp)

func indexOf*[T](self: SortedSet[T], val: T): int =
  ## val's index, or -1 when it isn't a member
  mixin cmp
  let i = self.lowerIdx(val)
  if i < self.data.len and cmp(self.data[i], val) == 0: i else: -1

func contains*[T](self: SortedSet[T], val: T): bool =
  self.indexOf(val) != -1

func incl*[T](self: var SortedSet[T], val: sink T) =
  mixin cmp
  let i = self.lowerIdx(val)
  if i < self.data.len and cmp(self.data[i], val) == 0:
    return
  self.data.insert(val, i)

func excl*[T](self: var SortedSet[T], val: T) =
  let i = self.indexOf(val)
  if i != -1:
    self.data.delete(i)

func getOr*[T](self: SortedSet[T], a, b: T): T =
  let i = self.indexOf(a)
  if i == -1:
    b
  else:
    self.data[i]

iterator items*[T](self: SortedSet[T]): lent T =
  for e in self.data:
    yield e

func `[]=`*[T](self: var SortedSet[T], val: sink T, included: bool) =
  if included:
    self.incl val
  else:
    self.excl val

func len*[T](self: SortedSet[T]): Natural =
  self.data.len

func low*[T](self: SortedSet[T]): lent T =
  self.data[0]

func high*[T](self: SortedSet[T]): lent T =
  self.data[self.data.len - 1]

# ================
# BNum
# ================

import std/[options, strutils]
import bigints

type BNum* = object
  case isBig*: bool
  of false:
    small*: int
  of true:
    big*: BigInt

func initNum*(n: BigInt): BNum =
  BNum(isBig: true, big: n)

func initNum*(n: SomeInteger): BNum =
  BNum(isBig: false, small: n.int)

func initNum*(s: string): BNum =
  ## s is a canonical spelling; past int64 it is held as it is spelled
  guard isValidInt(s), "not a canonical number: " & s
  try:
    BNum(isBig: false, small: parseBiggestInt(s))
  except ValueError:
    BNum(isBig: true, big: initBigInt(s, 10))

converter toNum*(n: SomeInteger): BNum =
  initNum(n)

converter toNum*(n: BigInt): BNum =
  initNum(n)

func `'num`*(s: string): BNum =
  initNum(s)

func isBig*(n: BNum): bool =
  n.isBig

func grow*(n: BNum): BNum =
  if n.isBig:
    n
  else:
    initNum(initBigInt(n.small))

func isInt*(n: BNum): bool =
  not n.isBig

func toInt*(n: BNum): int =
  if n.isBig:
    let x = toInt[int](n.big)
    guard x.isSome, "num is wide, not an int"
    x.get
  else:
    n.small

func toString*(n: BNum): string =
  if n.isBig:
    $n.big
  else:
    $n.small

func `$`*(n: BNum): string =
  n.toString

template lift(a, b, op): untyped =
  if a.isBig and b.isBig:
    return op(a.big, b.big)
  elif a.isBig:
    return op(a.big, initBigInt(b.small))
  elif b.isBig:
    return op(initBigInt(a.small), b.big)
  else:
    return op(a.small, b.small)

template binary(op, T) =
  func op*(a, b: BNum): T =
    when T is BNum:
      try:
        lift(a, b, op)
      except OverflowDefect:
        let
          x = a.grow
          y = b.grow
        lift(x, y, op)
    else:
      lift(a, b, op)

binary `+`, BNum
binary `-`, BNum
binary `*`, BNum
binary `div`, BNum
binary `mod`, BNum

binary `cmp`, int
binary `<`, bool
binary `<=`, bool
binary `==`, bool

func inc*(n: var BNum, by = 1) =
  n = n + by

func dec*(n: var BNum, by = 1) =
  n = n - by

func pow*(x: BNum, power: Natural): BNum =
  x.grow.big.pow(power)

func powmod*(x: BNum, power: int, modulus: Natural): BNum =
  x.grow.big.powmod(power, modulus)

iterator `..`*(a, b: BNum): BNum =
  ## Counts from `a` up to `b` (inclusive).
  var res = a
  while res <= b:
    yield res
    inc res

iterator `..<`*(a, b: BNum): BNum =
  ## Counts from `a` up to `b` (exclusive).
  var res = a
  while res < b:
    yield res
    inc res

func magnitude*(x: int): uint64 =
  ## |x| without the abs(int.low) overflow
  if x < 0:
    uint64(-(x + 1)) + 1
  else:
    uint64(x)

func abs*(n: BNum): BNum =
  if n.isBig:
    initNum(n.big.abs)
  else:
    let x = n.small
    if x < 0:
      initNum(x.magnitude)
    else:
      n

func spellingLen*(n: BNum): int =
  ## how many characters $n would take up
  if n < 0'num:
    inc result
  if n.isBig:
    # NOTE: bigints does a fast estimation for the size of the string here
    # so I will replace this later
    return len($n.big)
  else:
    let x = n.small
    var m = magnitude x
    result = if x < 0: 2 else: 1
    while m >= 10:
      inc result
      m = m div 10

func cmpInts*(x, y: int): int =
  ## ascii shortlex over the decimal strings
  ## without making them strings
  result = cmp(spellingLen(x), spellingLen(y))
  if result != 0:
    return
  let nx = x < 0
  let ny = y < 0
  if nx != ny:
    return if nx: -1 else: 1
  result = cmp(magnitude(x), magnitude(y))

func cmpNums*(x, y: BNum): int =
  if x.isBig or y.isBig:
    cmpShortlex(x.toString, y.toString)
  else:
    cmpInts(x.toInt, y.toInt)

# ================
# Value Object
# ================

type ValueObj* = object
  mark*: bool
  case kind*: Kind
  of bNil: discard
  of bNum:
    num*: BNum
  of bText, bSym:
    text*: string
  of bBytes:
    bytes*: string
  of bList, bRec:
    items*: seq[ValueObj]
  of bDict:
    dict*: SortedTable[ValueObj, ValueObj]
  of bSet:
    els*: SortedSet[ValueObj]

# ================
# Editable
# ================

proc setMark*(self: var ValueObj, mark: bool) =
  self.mark = mark

# ================
# Walkable
# ================

proc valid*(self: ValueObj): bool =
  true

proc kind*(self: ValueObj): Kind =
  self.kind

proc mark*(self: ValueObj): bool =
  self.mark

proc digits*(self: ValueObj): string =
  $self.num

proc payload*(self: ValueObj): lent string =
  let k: bText .. bBytes = self.kind
  case k
  of bText, bSym:
    return self.text
  of bBytes:
    return self.bytes

func len*(self: ValueObj): int =
  case self.kind
  of bList, bRec:
    self.items.len
  of bDict:
    self.dict.len * 2
  of bSet:
    self.els.len
  else:
    0

func getChild*(self: ValueObj, i: int): lent ValueObj =
  case self.kind
  of bList, bRec:
    return self.items[i]
  of bDict:
    if i mod 2 == 0:
      return self.dict.keys[i div 2]
    else:
      return self.dict.vals[i div 2]
  of bSet:
    return self.els.data[i]
  else:
    refuse("cannot get child from a non frame type")

iterator children*(self: ValueObj): lent ValueObj =
  let k: bList .. bSet = self.kind
  case k
  of bList, bRec:
    for v in self.items:
      yield v
  of bDict:
    for k, v in self.dict:
      yield k
      yield v
  of bSet:
    for v in self.els:
      yield v

func cmpNums*(a, b: ValueObj): int =
  cmpNums(a.num, b.num)

makeCmp(ValueObj)
makePrintable(ValueObj)

# ================
# Readable
# ================

proc buildNull*(T: typedesc[ValueObj], mark: bool): ValueObj =
  ValueObj(kind: bNil, mark: mark)

proc buildAtom*(T: typedesc[ValueObj], s: sink string, kind: Kind, mark: bool): ValueObj =
  let k: bNum .. bBytes = kind
  case k
  of bNum:
    ValueObj(kind: k, num: initNum(s), mark: mark)
  of bText, bSym:
    guard isValidUtf8(s.toBytes), "invalid utf8 bytes"
    ValueObj(kind: k, text: s, mark: mark)
  of bBytes:
    ValueObj(kind: k, bytes: s, mark: mark)

proc buildFrame*(
    T: typedesc[ValueObj], s: sink seq[ValueObj], kind: Kind, mark: bool
): ValueObj =
  let k: bList .. bSet = kind
  case k
  of bList, bRec:
    if k == bRec:
      guard s.len > 0, "record must have a head"
    ValueObj(kind: k, mark: mark, items: s)
  of bDict:
    guard s.len mod 2 == 0, "dict cannot have stranded keys"
    var
      keys = newSeqOfCap[ValueObj](s.len div 2)
      vals = newSeqOfCap[ValueObj](s.len div 2)
    for i in countup(0, s.len - 1, 2):
      guard keys.len == 0 or keys[^1] < s[i], "dict keys must be strictly ascending"
      keys.add move s[i]
      vals.add move s[i + 1]
    ValueObj(
      kind: bDict, mark: mark, dict: toSortedTable(move keys, move vals, sorted = true)
    )
  of bSet:
    for i in 1 ..< s.len:
      guard s[i - 1] < s[i], "set elements must be strictly ascending"
    ValueObj(kind: bSet, mark: mark, els: toSortedSet(s, sorted = true))