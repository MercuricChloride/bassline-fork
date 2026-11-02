import std/[algorithm, macros]
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
  when n is uint64 or n is uint:
    if n > uint64(high(int)):
      return BNum(isBig: true, big: initBigInt(uint64(n)))
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

func magnitude*(x: int): uint64 =
  ## |x| without the abs(int.low) overflow
  if x < 0:
    uint64(-(x + 1)) + 1
  else:
    uint64(x)

template wide(a, b, op): untyped =
  ## op over both as BigInts, a small one lifted
  if a.isBig and b.isBig:
    op(a.big, b.big)
  elif a.isBig:
    op(a.big, initBigInt(b.small))
  elif b.isBig:
    op(initBigInt(a.small), b.big)
  else:
    op(initBigInt(a.small), initBigInt(b.small))

template compare(op, T) =
  func op*(a, b: BNum): T =
    if a.isBig or b.isBig:
      wide(a, b, op)
    else:
      op(a.small, b.small)

compare `cmp`, int
compare `<`, bool
compare `<=`, bool
compare `==`, bool

func addFits(a, b: int): bool =
  if b >= 0: a <= high(int) - b else: a >= low(int) - b

func subFits(a, b: int): bool =
  if b >= 0: a >= low(int) + b else: a <= high(int) + b

func mulFits(a, b: int): bool =
  if a == 0 or b == 0:
    return true
  let most = if (a < 0) != (b < 0): magnitude(low(int)) else: magnitude(high(int))
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
    if not a.isBig and not b.isBig and fits(a.small, b.small):
      initNum(op(a.small, b.small))
    else:
      initNum(wide(a, b, wideOp))

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

type
  LayerVTable* = ref object
    readerDefs*: seq[ReaderProc]
    bindDefs*: seq[BinderProc]

  ReaderProc* = proc(v: Val): Layer {.nimcall, raises: [].}
    ## a layer read from a value alone, nil when it reads none

  BinderProc* = proc(self: Layer, v: Val): bool {.nimcall, raises: [].}
    ## whether a layer made apart from a value goes on it

  Layer* = ref object of RootObj
    ## what a value carries beside itself, never part of its identity
    vtable*: LayerVTable

  Layers* = object
    data: seq[Layer]

  Val* = ref object
    layers*: Layers
    value*: ValObj

  ValObj* = object
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
      items*: seq[Val]
    of bDict:
      dict*: SortedTable[Val, Val]
    of bSet:
      els*: SortedSet[Val]

proc kind*(self: Val): Kind =
  self.value.kind

proc mark*(self: Val): bool =
  self.value.mark

proc num*(self: Val): lent BNum =
  self.value.num

proc text*(self: Val): lent string =
  self.value.text

proc bytes*(self: Val): lent string =
  self.value.bytes

proc items*(self: Val): lent seq[Val] =
  self.value.items

proc dict*(self: Val): lent SortedTable[Val, Val] =
  self.value.dict

proc els*(self: Val): lent SortedSet[Val] =
  self.value.els

# ================
# Layers
# ================

proc add*(self: var Layers, layers: varargs[Layer]) =
  self.data.add layers

proc len*(self: Layers): int =
  self.data.len

iterator items*(self: Layers): Layer =
  for each in self.data:
    yield each

proc `[]`*[T: Layer](self: Layers, ty: typedesc[T]): T =
  for l in self:
    if l of ty: return ty(l)

macro layer*(def: untyped) =
  ## `layer Name(field: Type, …)` declares the layer type Name, its
  ## constructor `newName`, its readers and binders `Name.vtable`, and
  ## `Name.read`, which answers what the first reader to read one reads
  def.expectKind({nnkObjConstr, nnkCall})
  let
    name = def[0]
    newName = ident("new" & name.strVal)
    table = genSym(nskLet, name.strVal & "Vtable")
    vtable = ident"vtable"
  var
    fields = nnkRecList.newTree
    params = @[name]
    built = nnkObjConstr.newTree(name, nnkExprColonExpr.newTree(vtable, table))
  for each in def[1 .. ^1]:
    each.expectKind(nnkExprColonExpr)
    fields.add newIdentDefs(postfix(each[0], "*"), each[1])
    params.add newIdentDefs(each[0], each[1])
    built.add nnkExprColonExpr.newTree(each[0], each[0])
  let
    obj = nnkObjectTy.newTree(
      newEmptyNode(), nnkOfInherit.newTree(bindSym"Layer"), fields)
    ty = nnkTypeSection.newTree(nnkTypeDef.newTree(
      postfix(name, "*"), newEmptyNode(), nnkRefTy.newTree(obj)))
    construct = newProc(postfix(newName, "*"), params, built)
  quote do:
    `ty`
    let `table` = LayerVTable()
    `construct`
    proc `vtable`*(_: typedesc[`name`]): LayerVTable =
      `table`
    proc read*(_: typedesc[`name`], v: Val): `name` =
      for each in `table`.readerDefs:
        let got = each(v)
        if not got.isNil:
          return `name`(got)

macro reader*(def: untyped) =
  ## adds `proc p(v: Val): L` to L's readers, which take a refusal while
  ## it reads for reading nothing
  def.expectKind(nnkProcDef)
  let
    name = def.name
    layer = def.params[0]
    arg = def.params[1][0]
    wrapped = genSym(nskProc, name.strVal & "Reader")
  quote do:
    `def`
    proc `wrapped`(`arg`: Val): Layer {.nimcall, raises: [].} =
      try: Layer(`name`(`arg`))
      except BasslineError: nil
    `layer`.vtable.readerDefs.add `wrapped`

macro binder*(def: untyped) =
  ## adds `proc p(self: L, v: Val): bool` to L's binders, which take a
  ## refusal while it decides for a no
  def.expectKind(nnkProcDef)
  let
    name = def.name
    self = def.params[1][0]
    layer = def.params[1][1]
    arg = def.params[2][0]
    wrapped = genSym(nskProc, name.strVal & "Binder")
  quote do:
    `def`
    proc `wrapped`(`self`: Layer, `arg`: Val): bool {.nimcall, raises: [].} =
      try: `name`(`layer`(`self`), `arg`)
      except BasslineError: false
    `layer`.vtable.bindDefs.add `wrapped`

proc attach*[T: Layer](v: Val, ty: typedesc[T]): T =
  ## the T v carries, read from v and put on it when it carries none
  mixin read
  result = v.layers[T]
  if result.isNil:
    result = T.read(v)
    if not result.isNil:
      v.layers.add result

proc attach*(v: Val, layer: Layer): bool =
  ## whether v carries layer, put on it when the first of its binders
  ## to take v does
  for each in v.layers:
    if each == layer: return true
  for each in layer.vtable.bindDefs:
    if each(layer, v):
      v.layers.add layer
      return true

proc hasLayer*[T: Layer](v: Val, L: typedesc[T]): bool =
  not v.layers[L].isNil

proc `+`*[T: Layer](v: Val, l: typedesc[T]): Val {.discardable.} =
  discard v.attach(l)
  v

proc `+`*(v: Val, l: Layer): Val {.discardable.} =
  discard v.attach(l)
  v

# ================
# Walkable
# ================

template getter(name, field) =
  proc name*(self: Val): auto =
    return self.field

getter numVal, num
getter textVal, text
getter symVal, text
getter bytesVal, bytes

func len*(self: Val): int =
  case self.kind
  of bList, bRec:
    self.items.len
  of bDict:
    self.dict.len * 2
  of bSet:
    self.els.len
  else:
    0

func getChild*(self: Val, i: int): Val =
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

func `[]`*(self: Val, i: int): auto =
  return self.getChild(i)

iterator entries*(self: Val): tuple[key, val: Val] =
  for k, v in self.dict:
    yield (k, v)

makeCmp(Val)
makePrintable(Val)

# ================
# Readable
# ================

proc buildNull*(T: typedesc[Val], mark: bool): Val =
  Val(value: ValObj(kind: bNil, mark: mark))

proc buildAtom*(T: typedesc[Val], s: sink string, kind: Kind, mark: bool): Val =
  let k: bNum .. bBytes = kind
  case k
  of bNum:
    Val(value: ValObj(kind: k, num: initNum(s), mark: mark))
  of bText, bSym:
    guard isValidUtf8(s.toBytes), "invalid utf8 bytes"
    Val(value: ValObj(kind: k, text: s, mark: mark))
  of bBytes:
    Val(value: ValObj(kind: k, bytes: s, mark: mark))

proc buildFrame*(
    T: typedesc[Val], s: sink seq[Val], kind: Kind, mark: bool
): Val =
  let k: bList .. bSet = kind
  case k
  of bList, bRec:
    if k == bRec:
      guard s.len > 0, "record must have a head"
    Val(value: ValObj(kind: k, mark: mark, items: s))
  of bDict:
    guard s.len mod 2 == 0, "dict cannot have stranded keys"
    var
      keys = newSeqOfCap[Val](s.len div 2)
      vals = newSeqOfCap[Val](s.len div 2)
    for i in countup(0, s.len - 1, 2):
      guard keys.len == 0 or keys[^1] < s[i], "dict keys must be strictly ascending"
      keys.add move s[i]
      vals.add move s[i + 1]
    Val(value: ValObj(
      kind: bDict, mark: mark, dict: toSortedTable(move keys, move vals, sorted = true)
    ))
  of bSet:
    for i in 1 ..< s.len:
      guard s[i - 1] < s[i], "set elements must be strictly ascending"
    Val(value: ValObj(kind: bSet, mark: mark, els: toSortedSet(s, sorted = true)))

proc setMark*(self: var Val, mark: bool) =
  self.value.mark = mark

proc withMark*(v: Val): Val =
  ## a new node holding v's value, marked, and none of v's layers
  result = Val(value: v.value)
  result.value.mark = true