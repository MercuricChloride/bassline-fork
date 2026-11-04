import std/algorithm, macros, tables, options, strutils
import bigints
import ./ce, text

refuseWith BasslineError

# ================
# Sorted Table
# ================

type
  Entry*[K, V] = object
    key*: K
    val*: V

  Pair*[T] = Entry[T, T]
  SortedTable*[K, V] = object
    entries: seq[Entry[K, V]]

func toEntry*[T](self: sink array[2,T]): Entry[T,T] =
  Entry[T,T](key: self[0], val: self[1])

func toArray*[T](self: sink Entry[T,T]): array[2,T] =
  [self.key, self.val]

func entries*[K, V](self: SortedTable[K, V]): lent seq[Entry[K, V]] =
  self.entries

func cmpKeys*[K, V](a, b: Entry[K, V]): int =
  mixin cmp
  cmp(a.key, b.key)

func cmpKeys*[K, V](a: Entry[K, V], b: K): int =
  mixin cmp
  cmp(a.key, b)

func toSortedTable*[K, V](
    entries: sink seq[Entry[K, V]], sorted = false
): SortedTable[K, V] =
  mixin cmp
  if sorted:
    return SortedTable[K, V](entries: entries)
  # sorted as pairs, by a comparison that captures nothing, which the VM
  # can compile when this is instantiated for compile time too
  entries.sort(cmpKeys)
  SortedTable[K, V](entries: entries)

func toSortedTable*[K, V](
    self: openArray[Entry[K, V]], sorted = false
): SortedTable[K, V] =
  toSortedTable(@self, sorted)

func toSortedTable*[T](ravel: sink seq[T], sorted = false): SortedTable[T, T] =
  guard ravel.len mod 2 == 0, "ravel len must be even"
  var entries = newSeqOfCap[Entry[T, T]](ravel.len div 2)
  for i in countup(1, ravel.high, 2):
    entries.add Entry[T, T](key: move ravel[i - 1], val: move ravel[i])
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
    self.entries.insert(Entry[K,V](key: key, val: val), i)

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
    self.entries.insert Entry[K,V](key: key, val: val)
  self.entries[i].val

func getOr*[K, V](self: SortedTable[K, V], key: K, val: V): V =
  let i = self.indexOf(key)
  if i == -1:
    val
  else:
    self.entries[i].val

func contains*[K, V](self: SortedTable[K, V], key: K): bool =
  self.indexOf(key) != -1

iterator items*[K, V](self: SortedTable[K, V]): lent Entry[K,V] =
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
    try:
      BNum(isBig: true, big: initBigInt(s, 10))
    except ValueError:
      refuse("not a number: " & s)

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
  ReaderProc* = proc(v: Val): Layer {.nimcall, raises: [].}
    ## a layer read from a value alone, nil when it reads none

  BinderProc* = proc(self: Layer, v: Val): bool {.nimcall, raises: [].}
    ## whether a layer made apart from a value goes on it

  LayerVTable* = ref object
    ## A layer's readers and binders, each with its priority, the lowest
    ## number first. Those of one priority run in order of first added -> last added.
    ## `parent` is the vtable of the layer it inherits from, whose binders
    ## take its layers too
    readerDefs*: seq[(int, ReaderProc)]
    bindDefs*: seq[(int, BinderProc)]
    parent*: LayerVTable

  Layer* = ref object of RootObj
    ## what a value carries beside itself, never part of its identity
    vtable*: LayerVTable

  Layers* = object
    data: seq[Layer]

  LayerFlag* = enum
    ## lfPrivate keeps a layer to its module, and lfStatic to compile
    ## time: it has only the VM's vtable, so its readers, binders and
    ## constructor are never part of a program
    lfPrivate
    lfStatic

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

proc fresh*(v: Val): Val =
  ## a new node holding v's value and none of its layers
  Val(value: v.value)

# ================
# Layers
# ================

const
  LowPriority* = 100
  MedPriority* = 50
  HighPriority* = 25

proc add*(self: var Layers, layers: varargs[Layer]) =
  self.data.add layers

proc remove*(self: var Layers, layer: Layer) =
  ## takes that very layer off
  for i, each in self.data:
    if each == layer:
      self.data.delete(i)
      return

proc len*(self: Layers): int =
  self.data.len

iterator items*(self: Layers): Layer =
  for each in self.data:
    yield each

proc `[]`*[T: Layer](self: Layers, ty: typedesc[T]): T =
  for l in self:
    if l of ty:
      return ty(l)

proc ranked[P](defs: var seq[(int, P)], def: P, priority: int) =
  ## puts def after every def that runs before it or with it
  proc byPriority(d: (int, P), p: int): int =
    cmp(d[0], p)

  defs.insert((priority, def), defs.upperBound(priority, byPriority))

proc addReader*(vt: LayerVTable, def: ReaderProc, priority = MedPriority) =
  vt.readerDefs.ranked(def, priority)

proc addBinder*(vt: LayerVTable, def: BinderProc, priority = MedPriority) =
  vt.bindDefs.ranked(def, priority)

method mold*(l: Layer): Val {.base, raises: [BasslineError].} =
  ## the value l is written as, read back by the reader of its type that
  ## reads that form. nil when l can't be written. A layer declared with
  ## fields that are each a Val, string, int or BNum is written
  ## `(kebab-name FIELD …)` unless it says otherwise
  nil

proc kebab(name: string): string =
  ## `SlotPlace` as `slot-place`
  for i, c in name:
    if c in {'A' .. 'Z'}:
      if i > 0:
        result.add '-'
      result.add chr(ord(c) + 32)
    else:
      result.add c

proc exportRoutines(n: NimNode) =
  ## puts an export marker on each proc, method and template in n
  for each in n:
    if each.kind == nnkStmtList:
      each.exportRoutines
    elif each.kind in {nnkProcDef, nnkMethodDef, nnkTemplateDef} and
        each[0].kind != nnkPostfix:
      each[0] = postfix(each[0], "*")

proc written(name, newName: NimNode, fields: seq[NimNode]): NimNode =
  ## the layer's head in layerHeads and, when each field can be written,
  ## its `mold` as `(head FIELD …)` and a reader of that form
  let
    head = newLit(kebab(name.strVal))
    reads = genSym(nskProc, name.strVal & "Head")
  result = newStmtList quote do:
    proc `reads`(v: Val): Layer {.nimcall, raises: [].} =
      `name`.read(v)
  for each in fields:
    if not (
      each[1].kind == nnkIdent and each[1].strVal in ["Val", "string", "int", "BNum"]
    ):
      return
  let
    self = genSym(nskParam, "l")
    v = genSym(nskParam, "v")
    defaultReader = genSym(nskProc, name.strVal & "Default")
    moldField = ident"moldField"
    readField = ident"readField"
    members = nnkBracket.newTree(newCall(ident"headSym", head))
    built = newCall(newName)
    width = newLit(fields.len + 1)
  for i, each in fields:
    members.add newCall(moldField, newDotExpr(self, each[0]))
    built.add newCall(readField, newCall(ident"getChild", v, newLit(i + 1)), each[1])
  result.add quote do:
    method mold(`self`: `name`): Val =
      Val.buildFrame(@`members`, bRec, false)

    proc `defaultReader`(`v`: Val): Layer {.nimcall, raises: [].} =
      try:
        if `v`.kind == bRec and `v`.len == `width` and `v`.getChild(0) == headSym(
          `head`
        ):
          result = `built`
      except BasslineError:
        result = nil

    `name`.vtable.addReader(`defaultReader`, LowPriority)
    static:
      `name`.vtable.addReader(`defaultReader`, LowPriority)

proc layerDecls(defs: seq[NimNode], flags: set[LayerFlag]): NimNode =
  ## one type section declaring every layer in defs, so they may refer to
  ## each other, then each one's vtable, constructor, `read` and flags. A
  ## def is `Name(field: Type, …)` or `Name`, and `… of Base` inherits
  ## from the layer Base
  
  template shown(n): untyped =
    if lfPrivate in flags:
      n
    else:
      postfix(n, "*")

  var parsed: seq[tuple[name, base: NimNode, fields: seq[NimNode]]]
  for def in defs:
    var (shape, base) = (def, NimNode(nil))
    if def.kind == nnkInfix and def[0].eqIdent"of":
      (shape, base) = (def[1], def[2])
    if shape.kind == nnkIdent:
      parsed.add (shape, base, newSeq[NimNode]())
    else:
      shape.expectKind({nnkObjConstr, nnkCall})
      parsed.add (shape[0], base, shape[1 .. ^1])
  # a base declared here goes before its heirs, whose vtables point at it
  var
    ordered: typeof(parsed)
    done: seq[string]
    names: seq[string]
  for p in parsed:
    names.add $p.name
  while ordered.len < parsed.len:
    let before = ordered.len
    for p in parsed:
      if $p.name notin done and (p.base.isNil or $p.base notin names or $p.base in done):
        ordered.add p
        done.add $p.name
    if ordered.len == before:
      error("layers that inherit from each other in a cycle", defs[0])
  let
    types = nnkTypeSection.newTree
    vtable = ident"vtable"
    layerFlags = ident"layerFlags"
    read = ident"read"
    flagsLit = newLit(flags)
  result = newStmtList(types)
  for (name, base, defFields) in ordered:
    let
      newName = ident("new" & name.strVal)
      inherits =
        if base.isNil:
          bindSym"Layer"
        else:
          base
      fresh =
        if base.isNil:
          newCall(bindSym"LayerVTable")
        else:
          nnkObjConstr.newTree(
            bindSym"LayerVTable",
            nnkExprColonExpr.newTree(ident"parent", newDotExpr(base, vtable)),
          )
      table = genSym(nskLet, name.strVal & "Vtable")
      vmTable = genSym(nskVar, name.strVal & "VmVtable")
    var
      fields = nnkRecList.newTree
      params = @[name]
      built = nnkObjConstr.newTree(
        name, nnkExprColonExpr.newTree(vtable, newDotExpr(name, vtable))
      )
    for each in defFields:
      each.expectKind(nnkExprColonExpr)
      fields.add newIdentDefs(shown(each[0]), each[1])
      params.add newIdentDefs(each[0], each[1])
      built.add nnkExprColonExpr.newTree(each[0], each[0])
    let obj =
      nnkObjectTy.newTree(newEmptyNode(), nnkOfInherit.newTree(inherits), fields)
    types.add nnkTypeDef.newTree(shown(name), newEmptyNode(), nnkRefTy.newTree(obj))
    let construct = newProc(shown(newName), params, built)
    if lfStatic in flags:
      construct.addPragma ident"compileTime"
      result.add quote do:
        var `vmTable` {.compileTime.} = `fresh`
        proc `vtable`(_: typedesc[`name`]): LayerVTable {.compileTime.} =
          `vmTable`
    else:
      result.add quote do:
        let `table` = `fresh`
        var `vmTable` {.compileTime.} = `fresh`
        proc `vtable`(_: typedesc[`name`]): LayerVTable =
          when nimvm:
            result = `vmTable`
          else:
            result = `table`

    let readProc = quote:
      proc `read`(_: typedesc[`name`], v: Val): `name` =
        for (_, each) in `name`.`vtable`.readerDefs:
          let got = each(v)
          if not got.isNil:
            return `name`(got)

    if lfStatic in flags:
      readProc.addPragma ident"compileTime"
    result.add construct, readProc
    result.add quote do:
      template `layerFlags`(_: typedesc[`name`]): set[LayerFlag] {.used.} =
        `flagsLit`

    if lfStatic notin flags:
      result.add written(name, newName, defFields)
  if lfPrivate notin flags:
    result.exportRoutines

macro layersWith(flags: static set[LayerFlag], body: untyped) =
  body.expectKind(nnkStmtList)
  var defs: seq[NimNode]
  for each in body:
    if each.kind != nnkCommentStmt:
      defs.add each
  layerDecls(defs, flags)

macro layers*(args: varargs[untyped]) =
  ## `layers:` then `Name(field: Type, …)` on each line declares each layer
  ## type Name, its constructor `newName`, its readers and binders
  ## `Name.vtable`, and `Name.read`, which answers what the first reader to
  ## read one reads. The types are declared together, so they may refer to
  ## each other. The VM keeps a vtable of its own, so what runs at compile
  ## time sees the readers and binders added in `static` above it.
  ##
  ## `layers {lfPrivate}:` exports none of it, and with lfStatic the layers
  ## are made and read only at compile time. One macro takes both, since a
  ## block given where an overload takes static flags is checked as them
  case args.len
  of 1:
    newCall(bindSym"layersWith", nnkCurly.newTree, args[0])
  of 2:
    newCall(bindSym"layersWith", args[0], args[1])
  else:
    error("layers takes its flags, if any, then its block", args[0])

macro layer*(def: untyped, flags: static set[LayerFlag]) =
  ## `layer Name(field: Type, …)`, one layer declared as `layers` declares
  ## them, and `layer Name(…), {lfPrivate}` with flags
  layerDecls(@[def], flags)

template layer*(def: untyped) =
  layer(def, {})

proc readerOf(def, priority: NimNode): NimNode =
  def.expectKind(nnkProcDef)
  let
    name = def.name
    layer = def.params[0]
    arg = def.params[1][0]
    wrapped = genSym(nskProc, name.strVal & "Reader")
  quote:
    `def`
    proc `wrapped`(`arg`: Val): Layer {.nimcall, raises: [].} =
      try:
        Layer(`name`(`arg`))
      except BasslineError:
        nil

    when lfStatic notin `layer`.layerFlags:
      `layer`.vtable.addReader(`wrapped`, `priority`)
    static:
      `layer`.vtable.addReader(`wrapped`, `priority`)

macro reader*(def: untyped) =
  ## adds `proc p(v: Val): L` to L's readers, which take a refusal while
  ## it reads for reading nothing. `{.reader: HighPriority.}` gives it a
  ## priority, and without one it has MedPriority
  readerOf(def, bindSym"MedPriority")

macro reader*(priority, def: untyped) =
  readerOf(def, priority)

proc binderOf(def, priority: NimNode): NimNode =
  def.expectKind(nnkProcDef)
  let
    name = def.name
    self = def.params[1][0]
    layer = def.params[1][1]
    arg = def.params[2][0]
    wrapped = genSym(nskProc, name.strVal & "Binder")
  quote:
    `def`
    proc `wrapped`(`self`: Layer, `arg`: Val): bool {.nimcall, raises: [].} =
      try:
        `name`(`layer`(`self`), `arg`)
      except BasslineError:
        false

    when lfStatic notin `layer`.layerFlags:
      `layer`.vtable.addBinder(`wrapped`, `priority`)
    static:
      `layer`.vtable.addBinder(`wrapped`, `priority`)

macro binder*(def: untyped) =
  ## adds `proc p(self: L, v: Val): bool` to L's binders, which take a
  ## refusal while it decides for a no. `{.binder: HighPriority.}` gives it
  ## a priority, and without one it has MedPriority
  binderOf(def, bindSym"MedPriority")

macro binder*(priority, def: untyped) =
  binderOf(def, priority)

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
  ## to take v does, its own type's before those it inherits
  for each in v.layers:
    if each == layer:
      return true
  var table = layer.vtable
  while not table.isNil:
    for (_, each) in table.bindDefs:
      if each(layer, v):
        v.layers.add layer
        return true
    table = table.parent

proc attachAll*[T: Layer](v: Val, ty: typedesc[T]) =
  when nimvm:
    discard v.attach(T)
    for m in v.children:
      m.attachAll(T)
  else:
    for each in v.walk:
      discard each.attach ty

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

proc payload*(self: Val): string =
  case self.kind
  of bNum:
    $self.num
  of bText, bSym:
    self.text
  of bBytes:
    self.bytes
  else:
    ""

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

func getChild*(self: Val, i: int): lent Val =
  case self.kind
  of bList, bRec:
    return self.items[i]
  of bDict:
    return self.dict.getRavel(i)
  of bSet:
    return self.els.data[i]
  else:
    refuse("cannot get child from a non frame type")

iterator entries*(self: Val): tuple[key, val: Val] =
  for k, v in self.dict:
    yield (k, v)

makeCmp(Val)
makePrintable(Val)

func `[]`*(self: Val, i: int): lent Val =
  return self.getChild(i)

func `[]`*(self, key: Val): lent Val =
  guard self.kind == bDict, "expected a dict"
  return self.dict.get(key)

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

proc buildFrame*(T: typedesc[Val], s: sink seq[Val], kind: Kind, mark: bool): Val =
  let k: bList .. bSet = kind
  case k
  of bList, bRec:
    if k == bRec:
      guard s.len > 0, "record must have a head"
    Val(value: ValObj(kind: k, mark: mark, items: s))
  of bDict:
    guard s.len mod 2 == 0, "dict cannot have stranded keys"
    if s.len > 2:
      for i in countup(2, s.len - 1, 2):
        guard s[i-2] < s[i], "dict keys must be strictly ascending"
    Val(
      value: ValObj(
        kind: bDict,
        mark: mark,
        dict: toSortedTable(move s, sorted = true),
      )
    )
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