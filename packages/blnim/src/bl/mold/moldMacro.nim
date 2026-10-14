## `moldable`: a description of structs (see parseMold.nim) made into
## Moldable types. For each struct it generates the type, its fields
## public; `moldFields` and `loadFields`, reading and writing it by name;
## `shape`, which everything else in mold.nim works from; and the
## probes, `T.probe(v)` and the like, which check what a load would and
## build nothing.

import std/[macros, strutils, options, tables]
import ../core
import ./[mold, parseMold]

refuseWith MoldError

# ================ what the generated code calls ================

func fieldCmp(k: Value, name: string): int =
  ## k against the field named by the symbol `name`, in CE order,
  ## without making the symbol
  result = cmp(k.kind, bSym)
  if result != 0: return
  result = cmp(k.mark, false)
  if result != 0: return
  result = cmpShortlex(k.text.toBytes, name.toBytes)

func spelled(head: string, mark: bool, rest: string): string =
  (if mark: "!(" else: "(") & head & " " & rest & ")"

proc isHead(v: Value, head: string): bool =
  v.isKind(bSym) and not v.mark and v.text == head

proc dictFields(v: Value, head: string, mark: bool): BDict =
  ## the fields of `(head {…})`, marked as described
  guard v.isKind(bRec) and v.mark == mark and v.items.len == 2 and
    v.items[0].isHead(head) and v.items[1].isKind(bDict) and
    not v.items[1].mark, "not " & spelled(head, mark, "{…}")
  v.items[1].dict

proc recItems(v: Value, head: string, mark: bool, n: int,
              exact: bool): Buffer[Value] =
  ## the items of `(head …)`, marked as described: one for each field,
  ## and, read exactly, no more
  guard v.isKind(bRec) and v.mark == mark and
    (if exact: v.items.len == n + 1 else: v.items.len > n) and
    v.items[0].isHead(head),
    "not " & spelled(head, mark, "…") & " with " &
    (if exact: "exactly " else: "") & $n & " items"
  v.items

proc absent(v: Value): bool =
  ## nil, where an optional field has nothing in it
  v.isKind(bNil) and not v.mark

proc present(v: Value, name: string): Value =
  ## v, which a record can tell from nothing only when it isn't nil
  guard not v.absent, name & " holds nil, which a record can't tell from " &
    "nothing in it"
  v

proc missing(name: string) {.noreturn.} =
  refuse "no field " & name

proc beyond(head: string) {.noreturn.} =
  refuse head & " is read exactly, and holds a field more than described"

proc sized(v: Value, n: int, mark: bool, name: string) =
  ## v, which must be exactly n bytes, marked as described
  guard v.isKind(bBytes) and v.mark == mark and v.bytes.len == n,
    name & " must be " & (if mark: "marked " else: "") & $n & " bytes"

proc fixedBytes[N: static int](v: Value, mark: bool, name: string): array[N, byte] =
  ## v, which must be exactly N bytes, as the array that holds them
  sized(v, N, mark, name)
  if N > 0:
    copyMem(addr result[0], unsafeAddr v.bytes[0], N)

proc oneOf(s: string, allowed: openArray[string], name: string): string =
  guard s in allowed, name & " must be one of " & allowed.join(" ") &
    ", not " & s
  s

proc moldOf(m: Moldable, name: string): Value =
  ## m written down; a field with nothing in it has nothing to write
  guard m != nil, name & " is nil"
  m.mold

proc heldOf(v: Value, kind: Kind, mark: bool, name: string): lent Value =
  ## v, which must be of kind and marked as the field is: what holds it
  ## has no place for a mark, so the description says which it is
  guard v.isKind(kind) and v.mark == mark,
    name & " must be " & (if mark: "a marked " else: "an unmarked ") & $kind
  v

proc markedAs(v: Value, mark: bool, name: string): lent Value =
  ## v, of any kind, marked as the field is
  guard v.mark == mark,
    name & (if mark: " must be marked" else: " must be unmarked")
  v

proc copied(d: BDict): BDict =
  d.copy

proc copied(s: BSet): BSet =
  s.copy

# a container field is the object's own: what it is molded into or
# loaded from is a copy, so changing one never changes the other

proc recOf(items: sink seq[Value], name: string): Value =
  guard items.len > 0, name & " needs a head"
  initRec(items)

proc dictOf(d: BDict, name: string): Value =
  guard d != nil, name & " is nil"
  initDict(d.copied)

proc setOf(s: BSet, name: string): Value =
  guard s != nil, name & " is nil"
  initSet(s.copied)

# a typed collection is held in a seq, of members or of (key, val)
# entries; a set or dict has no place for one held twice

proc setOf(items: sink seq[Value], name: string): Value =
  let n = items.len
  result = initSet(items)
  guard result.len == n, name & " holds a member twice"

proc dictOf(entries: sink seq[(Value, Value)], name: string): Value =
  let n = entries.len
  result = initDict(entries)
  guard result.len == n, name & " holds a key twice"

# ================ from the tree to Nim ================

proc structNim(ctx: Context, name: string): string =
  ## the Nim name of the struct called `name`, declared here or elsewhere
  if name in ctx.structs: ctx.structs[name].nimName
  else: nimSpelling(name, true)

proc seqOf(ty: NimNode): NimNode =
  newTree(nnkBracketExpr, ident"seq", ty)

proc nimType(t: Type, ctx: Context): NimNode =
  ## what a part of TYPE t is held as
  case t.kind
  of tkKind:
    if t.len.isSome:
      return newTree(nnkBracketExpr, ident"array", newLit(t.len.get), ident"byte")
    case t.valueKind
    of bNum: bindSym"BNum"
    of bText, bSym: ident"string"
    of bBytes: seqOf(ident"byte")
    of bList, bRec: seqOf(bindSym"Value")
    of bDict: bindSym"BDict"
    of bSet: bindSym"BSet"
    of bNil: newEmptyNode() # not a TYPE
  of tkAny: bindSym"Value"
  of tkStruct: ident(ctx.structNim(t.name))
  of tkList, tkSet, tkRecord: seqOf(nimType(t.each, ctx))
  of tkDict:
    seqOf(newTree(nnkTupleTy,
      newIdentDefs(ident"key", nimType(t.key, ctx)),
      newIdentDefs(ident"val", nimType(t.val, ctx))))

proc allowed(t: Type): NimNode =
  result = newTree(nnkBracket)
  for o in t.oneOf: result.add newLit(o)

proc moldExpr(t: Type, x: NimNode, name: string, ctx: Context): NimNode =
  ## x, held as TYPE t, written down
  let nameLit = newLit(name)
  case t.kind
  of tkAny:
    return
      if t.markFree: x
      else: newCall(bindSym"markedAs", x, newLit(t.marked), nameLit)
  of tkStruct:
    return newCall(bindSym"moldOf", x, nameLit)
  of tkList, tkSet, tkRecord:
    let
      items = genSym(nskVar, "items")
      it = genSym(nskForVar, "it")
      each = moldExpr(t.each, it, name & " member", ctx)
      made = case t.kind
        of tkList: newCall(bindSym"initList", items)
        of tkRecord: newCall(bindSym"recOf", items, nameLit)
        else: newCall(bindSym"setOf", items, nameLit)
    result = quote do:
      block:
        var `items`: seq[Value]
        for `it` in `x`:
          `items`.add `each`
        `made`
  of tkDict:
    let
      entries = genSym(nskVar, "entries")
      it = genSym(nskForVar, "it")
      key = moldExpr(t.key, newDotExpr(it, ident"key"), name & " key", ctx)
      val = moldExpr(t.val, newDotExpr(it, ident"val"), name & " value", ctx)
      made = newCall(bindSym"dictOf", entries, nameLit)
    result = quote do:
      block:
        var `entries`: seq[(Value, Value)]
        for `it` in `x`:
          `entries`.add (`key`, `val`)
        `made`
  of tkKind:
    result =
      if t.len.isSome: newCall(bindSym"bytes", x)
      elif t.oneOf.len > 0:
        newCall(bindSym"sym", newCall(bindSym"oneOf", x, t.allowed, nameLit))
      else:
        case t.valueKind
        of bNum: newCall(bindSym"toValue", x)
        of bText: newCall(bindSym"text", x)
        of bSym: newCall(bindSym"sym", x)
        of bBytes: newCall(bindSym"bytes", x)
        of bList: newCall(bindSym"initList", x)
        of bRec: newCall(bindSym"recOf", x, nameLit)
        of bDict: newCall(bindSym"dictOf", x, nameLit)
        of bSet: newCall(bindSym"setOf", x, nameLit)
        of bNil: x # not a TYPE
  if t.marked:
    result = newCall(bindSym"withMark", result)

proc loadExpr(t: Type, v: NimNode, name: string, ctx: Context): NimNode =
  ## v, a Value, read as TYPE t
  let nameLit = newLit(name)
  case t.kind
  of tkAny:
    if t.markFree: v
    else: newCall(bindSym"markedAs", v, newLit(t.marked), nameLit)
  of tkStruct:
    newCall(bindSym"load", ident(ctx.structNim(t.name)), v)
  of tkList, tkSet, tkRecord, tkDict:
    let
      held = genSym(nskLet, "held")
      r = genSym(nskVar, "r")
      it = genSym(nskForVar, "it")
      ty = nimType(t, ctx)
      valueKind = case t.kind
        of tkList: bList
        of tkSet: bSet
        of tkRecord: bRec
        else: bDict
      got = newCall(bindSym"heldOf", v, newLit(valueKind), newLit(t.marked),
                    nameLit)
    var members, each: NimNode
    case t.kind
    of tkDict:
      members = newCall(bindSym"pairs", newDotExpr(held, ident"dict"))
      each = newTree(nnkTupleConstr,
        loadExpr(t.key, newDotExpr(it, ident"key"), name & " key", ctx),
        loadExpr(t.val, newDotExpr(it, ident"val"), name & " value", ctx))
    of tkSet:
      members = newDotExpr(held, ident"els")
      each = loadExpr(t.each, it, name & " member", ctx)
    else:
      members = newDotExpr(held, ident"items")
      each = loadExpr(t.each, it, name & " member", ctx)
    quote do:
      block:
        let `held` = `got`
        var `r`: `ty`
        for `it` in `members`:
          `r`.add `each`
        `r`
  of tkKind:
    if t.len.isSome:
      return newCall(newTree(nnkBracketExpr, bindSym"fixedBytes",
                             newLit(t.len.get)), v, newLit(t.marked), nameLit)
    let held = newCall(bindSym"heldOf", v, newLit(t.valueKind),
                       newLit(t.marked), nameLit)
    if t.oneOf.len > 0:
      return newCall(bindSym"oneOf", newDotExpr(held, ident"text"), t.allowed,
                     nameLit)
    case t.valueKind
    of bNum: newDotExpr(held, ident"num")
    of bText, bSym: newDotExpr(held, ident"text")
    of bBytes: newTree(nnkPrefix, ident"@", newDotExpr(held, ident"bytes"))
    of bList, bRec: newDotExpr(newDotExpr(held, ident"items"), ident"data")
    of bDict: newCall(bindSym"copied", newDotExpr(held, ident"dict"))
    of bSet: newCall(bindSym"copied", newDotExpr(held, ident"els"))
    of bNil: v # not a TYPE

proc probeExpr(t: Type, v: NimNode, name: string, ctx: Context): NimNode =
  ## v, a Value, checked as loadExpr reads it, and nothing built: it
  ## refuses where loadExpr refuses
  let nameLit = newLit(name)
  case t.kind
  of tkAny:
    if t.markFree:
      result = newTree(nnkDiscardStmt, newEmptyNode())
    else:
      result = newTree(nnkDiscardStmt,
        newCall(bindSym"markedAs", v, newLit(t.marked), nameLit))
  of tkStruct:
    result = newCall(ident"probe", ident(ctx.structNim(t.name)), v)
  of tkKind:
    if t.len.isSome:
      return newCall(bindSym"sized", v, newLit(t.len.get), newLit(t.marked),
                     nameLit)
    let held = newCall(bindSym"heldOf", v, newLit(t.valueKind),
                       newLit(t.marked), nameLit)
    result =
      if t.oneOf.len > 0:
        newTree(nnkDiscardStmt, newCall(bindSym"oneOf",
          newDotExpr(held, ident"text"), t.allowed, nameLit))
      else:
        newTree(nnkDiscardStmt, held)
  of tkList, tkSet, tkRecord, tkDict:
    let
      it = genSym(nskForVar, "it")
      valueKind = case t.kind
        of tkList: bList
        of tkSet: bSet
        of tkRecord: bRec
        else: bDict
      held = newCall(bindSym"heldOf", v, newLit(valueKind), newLit(t.marked),
                     nameLit)
    var members, each: NimNode
    case t.kind
    of tkDict:
      members = newCall(bindSym"pairs", newDotExpr(held, ident"dict"))
      each = newStmtList(
        probeExpr(t.key, newDotExpr(it, ident"key"), name & " key", ctx),
        probeExpr(t.val, newDotExpr(it, ident"val"), name & " value", ctx))
    of tkSet:
      members = newDotExpr(held, ident"els")
      each = probeExpr(t.each, it, name & " member", ctx)
    else:
      members = newDotExpr(held, ident"items")
      each = probeExpr(t.each, it, name & " member", ctx)
    result = quote do:
      for `it` in `members`:
        `each`

# ================ one struct ================

proc probeDecl(s: Struct, body: NimNode): NimNode =
  ## `proc probe*(t: typedesc[T], v: Value)`: declared ahead of every
  ## struct's body when body is empty, so structs may probe each other
  newProc(postfix(ident"probe", "*"),
    [newEmptyNode(),
     newIdentDefs(ident"t", newTree(nnkBracketExpr, ident"typedesc",
                                    ident(s.nimName))),
     newIdentDefs(ident"v", bindSym"Value")],
    body)

proc structDef(s: Struct, ctx: Context): tuple[typeDef, methods: NimNode] =
  let
    T = ident(s.nimName)
    selfM = genSym(nskParam, "self")
    entries = genSym(nskVar, "entries")
    selfL = genSym(nskParam, "self")
    fieldsL = genSym(nskParam, "fields")
    selfS = genSym(nskParam, "self")
    theShape = genSym(nskLet, "shape")
    n = newLit(s.fields.len)
    headLit = newLit(s.name)
    exactLit = newLit(s.exact)
    fieldCmp = bindSym"fieldCmp"
    missing = bindSym"missing"
    beyond = bindSym"beyond"
  var
    recList = newNimNode(nnkRecList)
    moldBody = newStmtList()
    locals = newStmtList()
    sets = newStmtList()
    nameLits = newTree(nnkBracket)
    optionalLits = newTree(nnkBracket)
    shapeNames = newTree(nnkBracket)
    shapeOptional = newTree(nnkBracket)
    localOf = newSeq[NimNode](s.fields.len)

  for f in s.fields:
    let held = nimType(f.typ, ctx)
    recList.add newIdentDefs(postfix(ident(f.nimName), "*"),
      if f.optional: newTree(nnkBracketExpr, bindSym"Option", held) else: held)
    shapeNames.add newCall(bindSym"sym", newLit(f.name))
    shapeOptional.add newLit(f.optional)

  # writing, and reading, by name: in the order a dict holds them
  for at, place in s.byName:
    let f = s.fields[place]
    let
      where = s.name & " " & f.name
      own = newDotExpr(selfM, ident(f.nimName))
      local = genSym(nskVar, f.nimName)
      held = nimType(f.typ, ctx)
    if f.optional:
      let add = newCall(ident"add", entries, newTree(nnkTupleConstr,
        newCall(bindSym"sym", newLit(f.name)),
        moldExpr(f.typ, newCall(bindSym"get", own), where, ctx)))
      moldBody.add quote do:
        if `own`.isSome: `add`
    else:
      moldBody.add newCall(ident"add", entries, newTree(nnkTupleConstr,
        newCall(bindSym"sym", newLit(f.name)), moldExpr(f.typ, own, where, ctx)))
    nameLits.add newLit(f.name)
    optionalLits.add newLit(f.optional)
    locals.add newTree(nnkVarSection, newIdentDefs(local,
      if f.optional: newTree(nnkBracketExpr, bindSym"Option", held) else: held))
    localOf[place] = local
    sets.add newAssignment(newDotExpr(selfL, ident(f.nimName)),
                           newCall(ident"move", local))

  # the walk by name, in the order a dict holds names: each field
  # described read where it is found, and every one not optional found
  proc namedWalk(fields: NimNode,
                 read: proc(f: Field, place: int, val: NimNode): NimNode):
                 NimNode =
    if s.fields.len == 0:
      return quote do:
        if `exactLit` and `fields`.len != 0: `beyond`(`headLit`)
    let
      i = genSym(nskVar, "i")
      e = genSym(nskForVar, "e")
      taken = genSym(nskVar, "taken")
      names = genSym(nskConst, "names")
      optionalNames = genSym(nskConst, "optional")
      reads = newTree(nnkCaseStmt, i)
      nameLits = nameLits.copyNimTree
      optionalLits = optionalLits.copyNimTree
    for at, place in s.byName:
      reads.add newTree(nnkOfBranch, newLit(at),
                        read(s.fields[place], place, newDotExpr(e, ident"val")))
    reads.add newTree(nnkElse, newTree(nnkDiscardStmt, newEmptyNode()))
    quote do:
      const `names` = `nameLits`
      const `optionalNames` = `optionalLits`
      var
        `i` = 0
        `taken` = 0
      for `e` in pairs(`fields`):
        while `i` < `n`:
          let c = `fieldCmp`(`e`.key, `names`[`i`])
          if c < 0: break # a field not described, left behind
          if c == 0:
            `reads`
            inc `i`
            inc `taken`
            break
          if not `optionalNames`[`i`]: `missing`(`names`[`i`])
          inc `i`
        if `i` == `n`: break
      while `i` < `n`:
        if not `optionalNames`[`i`]: `missing`(`names`[`i`])
        inc `i`
      if `exactLit` and `taken` != `fields`.len: `beyond`(`headLit`)

  # the record form: each field at its place, in the order described
  let
    selfR = genSym(nskParam, "self")
    items = genSym(nskVar, "items")
    selfI = genSym(nskParam, "self")
    src = genSym(nskParam, "items")
  var
    moldItems = newStmtList()
    itemLocals = newStmtList()
    itemSets = newStmtList()
  for k, f in s.fields:
    let
      where = s.name & " " & f.name
      own = newDotExpr(selfR, ident(f.nimName))
      local = genSym(nskLet, f.nimName)
      item = newTree(nnkBracketExpr, src, newLit(k + 1))
    if f.optional:
      var molded = moldExpr(f.typ, newCall(bindSym"get", own), where, ctx)
      if f.typ.kind == tkAny:
        molded = newCall(bindSym"present", molded, newLit(where))
      moldItems.add quote do:
        `items`.add(if `own`.isSome: `molded` else: null())
      let loaded = loadExpr(f.typ, item, where, ctx)
      itemLocals.add quote do:
        let `local` =
          if `item`.absent: none(typeof(`loaded`)) else: some(`loaded`)
    else:
      moldItems.add newCall(ident"add", items, moldExpr(f.typ, own, where, ctx))
      itemLocals.add newTree(nnkLetSection,
        newIdentDefs(local, newEmptyNode(), loadExpr(f.typ, item, where, ctx)))
    itemSets.add newAssignment(newDotExpr(selfI, ident(f.nimName)), local)

  let loadBody = newStmtList(locals,
    namedWalk(fieldsL, proc(f: Field, place: int, val: NimNode): NimNode =
      var loaded = loadExpr(f.typ, val, s.name & " " & f.name, ctx)
      if f.optional: loaded = newCall(bindSym"some", loaded)
      newAssignment(localOf[place], loaded)),
    sets)

  # probing: every check a load makes, in the same order, nothing built
  let
    fieldsP = genSym(nskParam, "fields")
    probeNamed = namedWalk(fieldsP,
      proc(f: Field, place: int, val: NimNode): NimNode =
        probeExpr(f.typ, val, s.name & " " & f.name, ctx))
    itemsP = genSym(nskLet, "items")
  var probeItems = newStmtList()
  for k, f in s.fields:
    let
      item = newTree(nnkBracketExpr, itemsP, newLit(k + 1))
      probed = probeExpr(f.typ, item, s.name & " " & f.name, ctx)
    if f.optional:
      probeItems.add quote do:
        if not `item`.absent: `probed`
    else:
      probeItems.add probed

  let
    objTy = newTree(nnkObjectTy, newEmptyNode(),
                    newTree(nnkOfInherit, bindSym"Moldable"), recList)
    marked = newLit(s.marked)
    rep = newLit(s.rep)
    description = newLit(s.shape.description)
    fromSorted = bindSym"fromSorted"
    ShapeT = bindSym"Shape"
    EntryT = bindSym"Entry"
  result.typeDef = newTree(nnkTypeDef, postfix(T, "*"), newEmptyNode(),
                           newTree(nnkRefTy, objTy))
  let
    moldNamed = genSym(nskProc, "moldNamed")
    fillNamed = genSym(nskProc, "fillNamed")
    moldRecord = genSym(nskProc, "moldRecord")
    fillRecord = genSym(nskProc, "fillRecord")
    dictFields = bindSym"dictFields"
    recItems = bindSym"recItems"

  # each method its own parameters: one symbol may not stand for two
  proc molds(form: Rep, self: NimNode): NimNode =
    if form == repDict:
      quote do:
        initRec(@[sym(`headLit`), initDict(`moldNamed`(`self`))], `marked`)
    else:
      quote do: `moldRecord`(`self`)
  proc loads(form: Rep, self, v: NimNode): NimNode =
    if form == repDict:
      quote do: `fillNamed`(`self`, `dictFields`(`v`, `headLit`, `marked`))
    else:
      quote do:
        `fillRecord`(`self`, `recItems`(`v`, `headLit`, `marked`, `n`, `exactLit`))
  proc moldMethod(name: string, form: Rep): NimNode =
    let self = genSym(nskParam, "self")
    let body = molds(form, self)
    let nameId = ident(name)
    quote do:
      method `nameId`(`self`: `T`): Value = `body`
  proc loadMethod(name: string, form: Rep): NimNode =
    let
      self = genSym(nskParam, "self")
      v = genSym(nskParam, "v")
      body = loads(form, self, v)
      nameId = ident(name)
    quote do:
      method `nameId`(`self`: `T`, `v`: Value) = `body`

  let
    selfF = genSym(nskParam, "self")
    selfG = genSym(nskParam, "self")
    fieldsG = genSym(nskParam, "fields")
  result.methods = quote do:
    let `theShape` = `ShapeT`(head: sym(`headLit`), marked: `marked`,
                             exact: `exactLit`, rep: `rep`,
                             names: @`shapeNames`, optional: @`shapeOptional`,
                             description: `description`)

    proc `moldNamed`(`selfM`: `T`): BDict =
      `selfM`.beforeMold()
      var `entries` = newSeqOfCap[`EntryT`[Value, Value]](`n`)
      `moldBody`
      `fromSorted`(`entries`)

    proc `fillNamed`(`selfL`: `T`, `fieldsL`: BDict) =
      `loadBody`

    proc `moldRecord`(`selfR`: `T`): Value =
      `selfR`.beforeMold()
      var `items` = newSeqOfCap[Value](`n` + 1)
      `items`.add sym(`headLit`)
      `moldItems`
      initRec(`items`, `marked`)

    proc `fillRecord`(`selfI`: `T`, `src`: Buffer[Value]) =
      `itemLocals`
      `itemSets`

    method shape(`selfS`: `T`): `ShapeT` = `theShape`
    method moldFields(`selfF`: `T`): BDict = `moldNamed`(`selfF`)
    method loadFields(`selfG`: `T`, `fieldsG`: BDict) = `fillNamed`(`selfG`, `fieldsG`)
  for m in [moldMethod("moldDict", repDict), loadMethod("loadDict", repDict),
            moldMethod("moldRec", repRecord), loadMethod("loadRec", repRecord),
            moldMethod("mold", s.rep), loadMethod("load", s.rep)]:
    result.methods.add m

  let
    tP = genSym(nskParam, "t")
    vD = genSym(nskParam, "v")
    tD = genSym(nskParam, "t")
    vR = genSym(nskParam, "v")
    tR = genSym(nskParam, "t")
    probeOwn =
      if s.rep == repDict: newCall(ident"probeDict", T, ident"v")
      else: newCall(ident"probeRec", T, ident"v")
  result.methods.add quote do:
    proc probeFields*(`tP`: typedesc[`T`], `fieldsP`: BDict) =
      ## the fields checked by name as `loadFields` reads them, nothing
      ## built; refuses where it refuses
      `probeNamed`

    proc probeDict*(`tD`: typedesc[`T`], `vD`: Value) =
      probeFields(`T`, `dictFields`(`vD`, `headLit`, `marked`))

    proc probeRec*(`tR`: typedesc[`T`], `vR`: Value) =
      let `itemsP` = `recItems`(`vR`, `headLit`, `marked`, `n`, `exactLit`)
      `probeItems`
  discard result.methods.add probeDecl(s, newStmtList(probeOwn))

# ================ moldable ================

macro moldableFrom(text: static[string], description: untyped): untyped =
  ## `moldable` given the description's text, and the expression it came
  ## from to point at when refusing it
  if text.strip.len == 0:
    error("the description is empty; a staticRead of a file that is " &
          "not there reads as empty", description)
  let ctx =
    try: parseMold(readValue(text))
    except BasslineError as e:
      error(e.msg, description)
  var
    types = newTree(nnkTypeSection)
    ahead = newStmtList()
    methods = newStmtList()
  for s in ctx.structs.values:
    let (typeDef, ms) = structDef(s, ctx)
    types.add typeDef
    ahead.add probeDecl(s, newEmptyNode())
    methods.add ms
  newStmtList(types, ahead, methods)

macro moldable*(description: untyped): untyped =
  ## `moldable "(struct NAME PRAGMAS? (FIELD PRAGMAS? TYPE) …)"`, or a set
  ## of structs declared together so they may name each other, declares
  ## a Moldable type for each (parseMold.nim has the grammar). Its fields
  ## are public, held as their TYPEs say: a number as a BNum, text and
  ## symbol as a string (`(one-of …)` checked), bytes as a seq[byte] or,
  ## with `(len N)`, an array[N, byte], an untyped list or record as a
  ## seq[Value], dict and set as a BDict and BSet (the object's own
  ## copies), `value` and `any` as a Value, a struct as its type, a typed
  ## list, set or record as a seq and a typed dict as a seq of (key, val),
  ## and an optional field as an Option.
  ##
  ## The description is any string known while compiling: a literal, a
  ## const, or `staticRead "types.bl"`.
  newCall(bindSym"moldableFrom", description, description)
