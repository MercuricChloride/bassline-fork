import std/[strutils, algorithm]
import bigints
import ./ce

refuseWith BasslineError

# ================
# BNum
# ================

type 
  BNum* = object
    case
    of Small: 
      small: int
    of Big: 
      big: BigInt

func initNum*(n: SomeInteger): BNum =
  when n is uint64 or n is uint:
    if n > uint64(high(int)):
      return Big(big: initBigInt(uint64(n)))
  Small(small: n.int)

func initNum*(n: BigInt): BNum =
  Big(big: n)

func initNum*(s: string): BNum =
  ## s is a canonical spelling; past int64 it is held as it is spelled
  guard isValidInt(s), "not a canonical number: " & s
  try:
    Small(small: parseBiggestInt(s))
  except ValueError:
    try:
      Big(big: initBigInt(s, 10))
    except ValueError:
      refuse("not a number: " & s)

converter toNum*(n: SomeInteger): BNum =
  initNum(n)

converter toNum*(n: BigInt): BNum =
  initNum(n)

func isInt*(n: BNum): bool =
  case n
  of Big: true
  else: false

func isBig*(n: BNum): bool =
  not n.isInt

func asInt*(n: BNum): int =
  case n
  of Big(n):
    let x = toInt[int](n)
    guard x.isSome, "num is wide, not an int"
    x.get
  of Small(n):
    n

func asBig*(n: BNum): BigInt =
  case n
  of Big(n): n
  of Small(n): initBigInt(n)

func `$`*(n: BNum): string =
  case n
  of Big(n): $n
  of Small(n): $n

func magnitude*(x: int): uint64 =
  ## |x| without the abs(int.low) overflow
  if x < 0:
    uint64(-(x + 1)) + 1
  else:
    uint64(x)

template compare(op, T) =
  func op*(a, b: BNum): T =
    if a.isBig or b.isBig:
      op(a.asBig, b.asBig)
    else:
      op(a.asInt, b.asInt)

compare `cmp`, int
compare `<`, bool
compare `<=`, bool
compare `==`, bool

func addFits(a, b: int): bool =
  if b >= 0:
    a <= high(int) - b
  else:
    a >= low(int) - b

func subFits(a, b: int): bool =
  if b >= 0:
    a >= low(int) + b
  else:
    a <= high(int) + b

func mulFits(a, b: int): bool =
  if a == 0 or b == 0:
    return true
  let most =
    if (a < 0) != (b < 0):
      magnitude(low(int))
    else:
      magnitude(high(int))
  magnitude(a) <= most div magnitude(b)

func divFits(a, b: int): bool =
  b != 0 and (a != low(int) or b != -1)

func truncated(a, b: BigInt): tuple[q, r: BigInt] =
  ## divmod(a,b) with rounding toward zero to match
  ## div rounding semantics with nim ints.
  let zero = initBigInt(0)
  guard b != zero, "division by zero"
  result = divmod(a, b)
  if result.r != zero and (a < zero) != (b < zero):
    result.q += initBigInt(1)
    result.r -= b

func quot(a, b: BigInt): BigInt =
  truncated(a, b).q

func rem(a, b: BigInt): BigInt =
  truncated(a, b).r

template arith(op, fits, wideOp) =
  func op*(a, b: BNum): BNum =
    if a.isInt and b.isInt and fits(a.asInt, b.asInt):
      initNum(op(a.asInt, b.asInt))
    else:
      initNum(wideOp(a.asBig, b.asBig))

arith `+`, addFits, `+`
arith `-`, subFits, `-`
arith `*`, mulFits, `*`
arith `div`, divFits, quot
arith `mod`, divFits, rem

func inc*(n: var BNum, by = 1) =
  n = n + by

func dec*(n: var BNum, by = 1) =
  n = n - by

func pow*(x: BNum, power: Natural): BNum =
  x.asBig.pow(power)

func powmod*(x: BNum, power: int, modulus: Natural): BNum =
  x.asBig.powmod(power, modulus)

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

func abs*(n: BNum): BNum =
  case n
  of Big(n):
    initNum(n.abs)
  of Small(n):
    let x = n.asInt
    if x < 0: initNum(x.magnitude)
    else: n

func strLen*(n: BNum): int =
  ## how many characters $n would take up
  if n < 0:
    inc result
  case n
  of Big(n):
    # NOTE: bigints does a fast estimation for the size of the string here
    # so I will replace this later
    return len($n)
  of Small(x):
    var m = magnitude x
    result = if x < 0: 2 else: 1
    while m >= 10:
      inc result
      m = m div 10

func cmpInts*(x, y: int): int =
  ## ascii shortlex over the decimal strings without making them strings
  result = cmp(strLen(x), strLen(y))
  if result != 0:
    return
  let nx = x < 0
  let ny = y < 0
  if nx != ny:
    return if nx: -1 else: 1
  result = cmp(magnitude(x), magnitude(y))

func cmpNums*(x, y: BNum): int =
  if x.isBig or y.isBig:
    cmpShortlex($x, $y)
  else:
    cmpInts(x.asInt, y.asInt)

# ================
# Sorted Table
# ================

type
  SortedEntry*[K, V] = object
    key*: K
    val*: V

  SortedPair*[T] = SortedEntry[T, T]
  SortedTable*[K, V] = object
    entries*: seq[SortedEntry[K, V]]

func toEntry*[T](self: sink array[2,T]): SortedEntry[T,T] =
  SortedEntry[T,T](key: self[0], val: self[1])

func toArray*[T](self: sink SortedEntry[T,T]): array[2,T] =
  [self.key, self.val]

func entries*[K, V](self: SortedTable[K, V]): lent seq[SortedEntry[K, V]] =
  self.entries

func cmpKeys*[K, V](a, b: SortedEntry[K, V]): int =
  mixin cmp
  cmp(a.key, b.key)

func cmpKeys*[K, V](a: SortedEntry[K, V], b: K): int =
  mixin cmp
  cmp(a.key, b)

func toSortedTable*[K, V](
    entries: sink seq[SortedEntry[K, V]], sorted = false
): SortedTable[K, V] =
  mixin cmp
  if sorted:
    return SortedTable[K, V](entries: entries)
  # sorted as pairs, by a comparison that captures nothing, which the VM
  # can compile when this is instantiated for compile time too
  entries.sort(cmpKeys)
  SortedTable[K, V](entries: entries)

func toSortedTable*[K, V](
    self: openArray[SortedEntry[K, V]], sorted = false
): SortedTable[K, V] =
  toSortedTable(@self, sorted)

func fromRavel*[T](ravel: sink seq[T], sorted = false): SortedTable[T, T] =
  guard ravel.len mod 2 == 0, "ravel len must be even"
  var entries = newSeqOfCap[SortedEntry[T, T]](ravel.len div 2)
  for i in countup(1, ravel.high, 2):
    entries.add SortedEntry[T, T](key: move ravel[i - 1], val: move ravel[i])
  toSortedTable(entries, sorted)

func toRavel*[T](self: sink SortedTable[T, T]): seq[T] =
  var s = newSeqOfCap[T](self.entries.len * 2)
  for each in self.entries.mitems:
    s.add move(each.key)
    s.add move(each.val)
  s

func lowerIdx[K, V](self: SortedTable[K, V], key: K): int =
  ## the first index whose key is not below key
  mixin cmp
  self.entries.lowerBound(key, cmpKeys)

func indexOf*[K, V](self: SortedTable[K, V], key: K): int =
  ## key's index, or -1 when it has none
  mixin cmp
  let i = self.lowerIdx(key)
  if i < self.len and cmpKeys(self.entries[i], key) == 0: i else: -1

func put*[K, V](self: var SortedTable[K, V], key: sink K, val: sink V) =
  mixin cmp
  let i = self.lowerIdx(key)
  if i < self.entries.len and cmpKeys(self.entries[i], key) == 0:
    self.entries[i].val = val
  else:
    self.entries.insert(SortedEntry[K,V](key: key, val: val), i)

func delete*[K, V](self: var SortedTable[K, V], key: K) =
  let i = self.indexOf(key)
  if i != -1:
    self.entries.delete(i)

func get*[K, V](self: SortedTable[K, V], key: K): lent V =
  let i = self.indexOf(key)
  if i == -1:
    raise newException(KeyError, "key not found")
  self.entries[i].val

func getRavel*[T](self: SortedTable[T,T], i: int): lent T =
  if i mod 2 == 0:
    return self.entries[i div 2].key
  else:
    return self.entries[i div 2].val

func len*[K, V](self: SortedTable[K, V]): Natural =
  self.entries.len

func low*[K, V](self: SortedTable[K, V]): lent K =
  self.entries[0].key

func high*[K, V](self: SortedTable[K, V]): lent K =
  self.entries[self.entries.high].key

# ================
# Table Sugar
# ================

func getOrPut*[K, V](self: var SortedTable[K, V], key: K, val: sink V): lent V =
  mixin cmp
  let i = self.lowerIdx(key)
  if i == self.entries.len or cmpKeys(self.entries[i], key) != 0:
    self.entries.insert SortedEntry[K,V](key: key, val: val)
  self.entries[i].val

func getOr*[K, V](self: SortedTable[K, V], key: K, val: V): V =
  let i = self.indexOf(key)
  if i == -1:
    val
  else:
    self.entries[i].val

func contains*[K, V](self: SortedTable[K, V], key: K): bool =
  self.indexOf(key) != -1

iterator items*[K, V](self: SortedTable[K, V]): lent SortedEntry[K,V] =
  for each in self.entries:
    yield each

iterator pairs*[K, V](self: SortedTable[K, V]): (lent K, lent V) =
  for i in 0 ..< self.entries.len:
    yield (self.entries[i].key, self.entries[i].val)

func `[]`*[K, V](self: SortedTable[K, V], key: K): lent V =
  self.get(key)

func `[]`*[K, V](self: var SortedTable[K, V], key: K): var V =
  let i = self.indexOf(key)
  if i == -1:
    raise newException(KeyError, "key not found")
  self.entries[i].val

func `[]=`*[K, V](self: var SortedTable[K, V], key: sink K, val: sink V) =
  self.put(key, val)

proc sort*[K,V](self: var SortedTable[K,V]) =
  self.entries.sort(cmpKeys)

# ================
# Sorted Set
# ================

type SortedSet*[T] {.byref.} = object
  data*: seq[T]

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