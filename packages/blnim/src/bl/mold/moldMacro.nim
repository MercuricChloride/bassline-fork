import std/[macros, strutils, options]
import ../core
import ./mold

refuseWith MoldError

# ================ What `moldable` writes calls ================

func spelled(head: string, mark: bool, rest: string): string =
  (if mark: "!(" else: "(") & head & " " & rest & ")"

proc fieldsOf(v: Value, head: string, mark: bool): BDict =
  ## the fields of `(head {…})`: marked as described, with that head, and
  ## an unmarked dict
  guard v.isKind(bRec) and v.mark == mark and v.items.len == 2 and
    v.items[0].isKind(bSym) and not v.items[0].mark and
    v.items[0].text == head and
    v.items[1].isKind(bDict) and not v.items[1].mark,
    "not " & spelled(head, mark, "{…}")
  v.items[1].dict

proc headlessFields(v: Value, head: string): BDict =
  guard v.isKind(bDict) and not v.mark,
    head & " reads its fields from an unmarked dict"
  v.dict

proc itemsOf(v: Value, head: string, mark: bool, n: int,
             exact: bool): Buffer[Value] =
  ## the items of `(head …)`: marked as described, with that head, and
  ## the n items described after it, or, read exactly, those and no more
  guard v.isKind(bRec) and v.mark == mark and
    (if exact: v.items.len == n + 1 else: v.items.len > n) and
    v.items[0].isKind(bSym) and not v.items[0].mark and
    v.items[0].text == head,
    "not " & spelled(head, mark, "…") & " with " &
    (if exact: "exactly " else: "") & $n & " items"
  v.items

proc headlessItems(v: Value, head: string, n: int, exact: bool): Buffer[Value] =
  guard v.isKind(bList) and not v.mark and
    (if exact: v.items.len == n else: v.items.len >= n),
    head & " reads " & (if exact: "exactly " else: "") & "its " & $n &
    " items from an unmarked list, or its fields by name from an unmarked " &
    "dict"
  v.items

func fieldCmp(k: Value, name: string): int =
  ## k against the field named by the symbol `name`, in CE order,
  ## without making the symbol
  result = cmp(k.kind, bSym)
  if result != 0: return
  result = cmp(k.mark, false)
  if result != 0: return
  result = cmpShortlex(k.text.toBytes, name.toBytes)

proc missing(name: string) {.noreturn.} =
  refuse "no field " & name

proc beyond(head: string) {.noreturn.} =
  refuse head & " is read exactly, and holds a field more than described"

proc fixedBytes[N: static int](v: Value, mark: bool, name: string): array[N, byte] =
  ## v, which must be exactly N bytes, marked as described
  guard v.isKind(bBytes) and v.mark == mark and v.bytes.len == N,
    name & " must be " & (if mark: "marked " else: "") & $N & " bytes"
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

func withMark(v: sink Value): Value =
  result = v
  result.mark = true

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

# ================ moldable ================

proc only(t: Value): Value =
  ## the one member of a typed set
  for m in t.els: return m

proc member(t: Value): Value =
  if t.isKind(bSet): only(t) else: t[0]

proc entry(t: Value): (Value, Value) =
  ## the one KEY: VALUE of a typed dict
  for k, v in t.dict: return (k, v)

func headed(t: Value, head: string): bool =
  t.isKind(bRec) and t.len > 0 and t[0].isKind(bSym) and not t[0].mark and
    t[0].text == head

func isOptional(t: Value): bool =
  ## whether t is `(optional T)`
  t.headed("optional") and t.len == 2

func isFixedBytes(t: Value): bool =
  ## whether t is `(bytes N)`
  t.headed("bytes") and t.len == 2

func isOneOf(t: Value): bool =
  ## whether t is `(one-of SYMBOL …)`
  t.headed("one-of") and t.len >= 2

func fixedLen(t: Value): int =
  t[1].num.toInt

proc allowed(t: Value): NimNode =
  ## the symbols `(one-of …)` lists, as an array of strings
  result = newTree(nnkBracket)
  for i in 1 ..< t.len:
    result.add newLit(t[i].text)

proc checkSpec(t: Value, name: string, description: NimNode) =
  ## refuses, while compiling, a TYPE that nothing can be held as
  template refuse(msg: string) =
    error(name & ": " & msg, description)
  if t.isOptional:
    refuse "only a field can be optional, by being left out: " & $t
  if t.isFixedBytes:
    if not t[1].isKind(bNum) or t[1].mark or t[1].num.isWide or
        t[1].num.toInt < 0:
      refuse "(bytes N) takes a count of bytes: " & $t
    return
  if t.isOneOf:
    for i in 1 ..< t.len:
      if not t[i].isKind(bSym) or t[i].mark:
        refuse "(one-of …) lists unmarked symbols: " & $t
    return
  case t.kind
  of bText, bSym:
    if t.text == "nil": refuse "nil holds nothing"
    elif t.text == "any":
      if t.mark: refuse "any is marked or not, so needs no mark"
    elif t.text != "value" and parseKind(t.text).isNone:
      if not validIdentifier(t.text): refuse "not a Nim type: " & t.text
      if t.mark: refuse "a Moldable is marked as its own description says"
  of bList, bRec, bSet:
    if t.len != 1: refuse "a typed " & $t.kind & " has one TYPE: " & $t
    checkSpec(t.member, name & " member", description)
  of bDict:
    if t.len != 1: refuse "a typed dict has one KEY: VALUE: " & $t
    let (k, v) = t.entry
    checkSpec(k, name & " key", description)
    checkSpec(v, name & " value", description)
  of bNil:
    refuse "nil holds nothing"
  else:
    refuse "a TYPE is a kind, value, any or a Moldable by name, or a " &
      "typed collection: " & $t

proc seqOf(ty: NimNode): NimNode =
  newTree(nnkBracketExpr, ident"seq", ty)

proc nimType(t: Value): NimNode =
  ## what a field of TYPE t is held as
  if t.isFixedBytes:
    return newTree(nnkBracketExpr, ident"array", newLit(t.fixedLen), ident"byte")
  if t.isOneOf:
    return ident"string"
  case t.kind
  of bList, bRec, bSet:
    seqOf(nimType(t.member))
  of bDict:
    let (k, v) = t.entry
    seqOf(newTree(nnkTupleTy,
      newIdentDefs(ident"key", nimType(k)),
      newIdentDefs(ident"val", nimType(v))))
  else:
    if t.text in ["value", "any"]: return bindSym"Value"
    let kind = parseKind(t.text)
    if kind.isNone: return ident(t.text)
    case kind.get
    of bNum: bindSym"BNum"
    of bText, bSym: ident"string"
    of bBytes: seqOf(ident"byte")
    of bList, bRec: seqOf(bindSym"Value")
    of bDict: bindSym"BDict"
    of bSet: bindSym"BSet"
    of bNil: newEmptyNode() # refused by checkSpec

proc moldExpr(t: Value, x: NimNode, name: string): NimNode =
  ## x, held as TYPE t, written down
  let nameLit = newLit(name)
  if t.isFixedBytes or t.isOneOf:
    result =
      if t.isFixedBytes: newCall(bindSym"bytes", x)
      else: newCall(bindSym"sym", newCall(bindSym"oneOf", x, t.allowed, nameLit))
    if t.mark:
      result = newCall(bindSym"withMark", result)
    return
  case t.kind
  of bList, bRec, bSet:
    let
      items = genSym(nskVar, "items")
      it = genSym(nskForVar, "it")
      each = moldExpr(t.member, it, name & " member")
      made = case t.kind
        of bList: newCall(bindSym"initList", items)
        of bRec: newCall(bindSym"recOf", items, nameLit)
        else: newCall(bindSym"setOf", items, nameLit)
    result = quote do:
      block:
        var `items`: seq[Value]
        for `it` in `x`:
          `items`.add `each`
        `made`
  of bDict:
    let
      (k, v) = t.entry
      entries = genSym(nskVar, "entries")
      it = genSym(nskForVar, "it")
      key = moldExpr(k, newDotExpr(it, ident"key"), name & " key")
      val = moldExpr(v, newDotExpr(it, ident"val"), name & " value")
      made = newCall(bindSym"dictOf", entries, nameLit)
    result = quote do:
      block:
        var `entries`: seq[(Value, Value)]
        for `it` in `x`:
          `entries`.add (`key`, `val`)
        `made`
  else:
    if t.text == "any": return x
    if t.text == "value":
      return newCall(bindSym"markedAs", x, newLit(t.mark), nameLit)
    let kind = parseKind(t.text)
    if kind.isNone: return newCall(bindSym"moldOf", x, nameLit)
    result = case kind.get
      of bNum: newCall(bindSym"toValue", x)
      of bText: newCall(bindSym"text", x)
      of bSym: newCall(bindSym"sym", x)
      of bBytes: newCall(bindSym"bytes", x)
      of bList: newCall(bindSym"initList", x)
      of bRec: newCall(bindSym"recOf", x, nameLit)
      of bDict: newCall(bindSym"dictOf", x, nameLit)
      of bSet: newCall(bindSym"setOf", x, nameLit)
      of bNil: x # refused by checkSpec
  if t.mark:
    result = newCall(bindSym"withMark", result)

proc loadExpr(t: Value, v: NimNode, name: string): NimNode =
  ## v, a Value, read as TYPE t
  let nameLit = newLit(name)
  if t.isFixedBytes:
    return newCall(newTree(nnkBracketExpr, bindSym"fixedBytes", newLit(t.fixedLen)),
                   v, newLit(t.mark), nameLit)
  if t.isOneOf:
    let sym = newCall(bindSym"heldOf", v, newLit(bSym), newLit(t.mark), nameLit)
    return newCall(bindSym"oneOf", newDotExpr(sym, ident"text"), t.allowed,
                   nameLit)
  case t.kind
  of bList, bRec, bSet, bDict:
    let
      held = genSym(nskLet, "held")
      r = genSym(nskVar, "r")
      it = genSym(nskForVar, "it")
      ty = nimType(t)
      got = newCall(bindSym"heldOf", v, newLit(t.kind), newLit(t.mark), nameLit)
    var members, each: NimNode
    case t.kind
    of bDict:
      let (k, v) = t.entry
      members = newCall(bindSym"pairs", newDotExpr(held, ident"dict"))
      each = newTree(nnkTupleConstr,
        loadExpr(k, newDotExpr(it, ident"key"), name & " key"),
        loadExpr(v, newDotExpr(it, ident"val"), name & " value"))
    of bSet:
      members = newDotExpr(held, ident"els")
      each = loadExpr(t.member, it, name & " member")
    else:
      members = newDotExpr(held, ident"items")
      each = loadExpr(t.member, it, name & " member")
    result = quote do:
      block:
        let `held` = `got`
        var `r`: `ty`
        for `it` in `members`:
          `r`.add `each`
        `r`
  else:
    if t.text == "any": return v
    if t.text == "value":
      return newCall(bindSym"markedAs", v, newLit(t.mark), nameLit)
    let kind = parseKind(t.text)
    if kind.isNone: return newCall(bindSym"load", ident(t.text), v)
    let held = newCall(bindSym"heldOf", v, newLit(kind.get), newLit(t.mark),
                       nameLit)
    result = case kind.get
      of bNum: newDotExpr(held, ident"num")
      of bText, bSym: newDotExpr(held, ident"text")
      of bBytes: newTree(nnkPrefix, ident"@", newDotExpr(held, ident"bytes"))
      of bList, bRec: newDotExpr(newDotExpr(held, ident"items"), ident"data")
      of bDict: newCall(bindSym"copied", newDotExpr(held, ident"dict"))
      of bSet: newCall(bindSym"copied", newDotExpr(held, ident"els"))
      of bNil: v # refused by checkSpec

proc buildMoldable(f: BDict, selfM, fieldsM, selfL, fieldsL: NimNode,
                   head: string, exact: bool, description: NimNode):
    tuple[recList, moldBody, loadBody: NimNode] =
  ## the type's fields, and the statements writing and reading them.
  ## Writing adds `(sym NAME, …)` to the seq `fieldsM` in CE order, the
  ## order f holds them in, leaving out an optional field that is none.
  ## Reading walks `fieldsL` once in that order, leaving behind any field
  ## not described (or, read exactly, refusing it), into one local per
  ## field, and sets them on `selfL` only once every one is read; an
  ## optional field not there is none
  result = (newNimNode(nnkRecList), newStmtList(), newStmtList())
  let
    i = genSym(nskVar, "i")
    e = genSym(nskForVar, "e")
    names = genSym(nskConst, "names")
    optional = genSym(nskConst, "optional")
    taken = genSym(nskVar, "taken")
    headLit = newLit(head)
    exactLit = newLit(exact)
    beyond = bindSym"beyond"
    reads = newTree(nnkCaseStmt, i)
    n = newLit(f.len)
  var
    nameLits = newTree(nnkBracket)
    optionalLits = newTree(nnkBracket)
    locals = newStmtList()
    sets = newStmtList()
    at = 0
  for k, t in f:
    if not k.isKind(bSym) or k.mark or not validIdentifier(k.text):
      error("a field is named by an unmarked symbol that is a Nim " &
            "identifier: " & $k, description)
    let
      opt = t.isOptional
      inner = if opt: t[1] else: t
    if opt and t.mark:
      error(k.text & ": optional takes no mark", description)
    checkSpec(inner, k.text, description)
    let
      name = newLit(k.text)
      field = ident(k.text)
      local = genSym(nskVar, k.text)
      own = newDotExpr(selfM, field)
      held =
        if opt: newTree(nnkBracketExpr, bindSym"Option", nimType(inner))
        else: nimType(inner)
    result.recList.add newIdentDefs(postfix(field, "*"), held)
    if opt:
      let add = newCall(ident"add", fieldsM, newTree(nnkTupleConstr,
        newCall(bindSym"sym", name),
        moldExpr(inner, newCall(bindSym"get", own), k.text)))
      result.moldBody.add quote do:
        if `own`.isSome: `add`
    else:
      result.moldBody.add newCall(ident"add", fieldsM, newTree(nnkTupleConstr,
        newCall(bindSym"sym", name), moldExpr(inner, own, k.text)))
    nameLits.add name
    optionalLits.add newLit(opt)
    locals.add newTree(nnkVarSection, newIdentDefs(local, held))
    var loaded = loadExpr(inner, newDotExpr(e, ident"val"), k.text)
    if opt: loaded = newCall(bindSym"some", loaded)
    reads.add newTree(nnkOfBranch, newLit(at), newAssignment(local, loaded))
    sets.add newAssignment(newDotExpr(selfL, field),
                           newCall(ident"move", local))
    inc at
  if f.len == 0:
    if exact:
      result.loadBody = quote do:
        if `fieldsL`.len != 0: `beyond`(`headLit`)
    return
  reads.add newTree(nnkElse, newTree(nnkDiscardStmt, newEmptyNode()))
  let
    fieldCmp = bindSym"fieldCmp"
    missing = bindSym"missing"
  result.loadBody = quote do:
    const `names` = `nameLits`
    const `optional` = `optionalLits`
    `locals`
    var
      `i` = 0
      `taken` = 0
    for `e` in pairs(`fieldsL`):
      while `i` < `n`:
        let c = `fieldCmp`(`e`.key, `names`[`i`])
        if c < 0: break # a field not described, left behind
        if c == 0:
          `reads`
          inc `i`
          inc `taken`
          break
        if not `optional`[`i`]: `missing`(`names`[`i`])
        inc `i`
      if `i` == `n`: break
    while `i` < `n`:
      if not `optional`[`i`]: `missing`(`names`[`i`])
      inc `i`
    if `exactLit` and `taken` != `fieldsL`.len: `beyond`(`headLit`)
    `sets`

proc positionalFields(f: Value, description: NimNode): seq[(string, Value)] =
  ## the `(NAME TYPE)` of a positional description, in order
  if f.mark:
    error("a positional description is an unmarked list: " & $f, description)
  for m in f.items:
    if not m.isKind(bRec) or m.mark or m.len != 2 or not m[0].isKind(bSym) or
        m[0].mark or not validIdentifier(m[0].text):
      error("a positional field is (NAME TYPE), NAME an unmarked symbol " &
            "that is a Nim identifier: " & $m, description)
    let (name, t) = (m[0].text, m[1])
    if t.isOptional:
      error(name & ": an item has no place to be left out, so it can't " &
            "be optional", description)
    checkSpec(t, name, description)
    for (seen, _) in result:
      if seen == name:
        error(name & " is described twice", description)
    result.add (name, t)

proc positionalMold(fs: seq[(string, Value)], self, items: NimNode): NimNode =
  ## `items.add …` for each field, in order
  result = newStmtList()
  for (name, t) in fs:
    result.add newCall(ident"add", items,
      moldExpr(t, newDotExpr(self, ident(name)), name))

proc buildPositional(fs: seq[(string, Value)], selfL, src, off: NimNode):
    tuple[recList, loadBody: NimNode] =
  ## the type's fields, and the statements reading item `off + k` of
  ## `src` as field k into a local, setting them on `selfL` only once
  ## every one is read
  result = (newNimNode(nnkRecList), newStmtList())
  var sets = newStmtList()
  for k, (name, t) in fs:
    let
      field = ident(name)
      local = genSym(nskVar, name)
      item = newTree(nnkBracketExpr, src, infix(off, "+", newLit(k)))
    result.recList.add newIdentDefs(postfix(field, "*"), nimType(t))
    result.loadBody.add newTree(nnkVarSection,
      newIdentDefs(local, newEmptyNode(), loadExpr(t, item, name)))
    sets.add newAssignment(newDotExpr(selfL, field),
                           newCall(ident"move", local))
  result.loadBody.add sets

proc moldDef(desc: Value, description: NimNode):
    tuple[name: string, typeDef, methods: NimNode] =
  ## the type of one `(HEAD ALIAS? {FIELD: TYPE …} exact?)` or
  ## `(HEAD ALIAS? [(NAME TYPE) …] exact?)`, and its mold and load;
  ## written marked when the description is, and read exactly when it
  ## says so
  template refuse =
    error("expected (HEAD ALIAS? {FIELD: TYPE …} exact?) or " &
          "(HEAD ALIAS? [(NAME TYPE) …] exact?): " & $desc, description)
  if not desc.isKind(bRec) or desc.len < 2: refuse
  let at = if desc[1].isKind({bDict, bList}): 1 else: 2
  if desc.len <= at or not desc[at].isKind({bDict, bList}): refuse
  let
    alias = desc[at - 1]
    f = desc[at]
  if not desc[0].isKind(bSym) or not alias.isKind(bSym): refuse
  var exact = false
  for i in at + 1 ..< desc.len:
    if exact or not desc[i].isKind(bSym) or desc[i].mark or
        desc[i].text != "exact":
      error("after its fields a description takes only `exact`: " & $desc,
            description)
    exact = true
  if desc[0].mark or alias.mark:
    error("a head and a type's name are unmarked symbols: " & $desc,
          description)
  let name = alias.text
  if not validIdentifier(name):
    error("a type's name must be a Nim identifier: " & name, description)
  let
    T = ident(name)
    head = newLit(desc[0].text)
    mark = newLit(desc.mark)
    exactLit = newLit(exact)
    n = newLit(f.len)
    fill = genSym(nskProc, "fill")
    selfM = genSym(nskParam, "self")
    selfMold = genSym(nskParam, "self")
    selfHead = genSym(nskParam, "self")
    selfMarked = genSym(nskParam, "self")
    selfL = genSym(nskParam, "self")
    selfHeadless = genSym(nskParam, "self")
    selfLoad = genSym(nskParam, "self")
    selfHeadlessM = genSym(nskParam, "self")
    v = genSym(nskParam, "v")
    vHeadless = genSym(nskParam, "v")
    sym = bindSym"sym"
  var recList, methods: NimNode
  if f.isKind(bDict):
    let
      fieldsM = genSym(nskVar, "fields")
      fieldsL = genSym(nskParam, "fields")
      built = buildMoldable(f.dict, selfM, fieldsM, selfL, fieldsL,
                            desc[0].text, exact, description)
      moldBody = built.moldBody
      loadBody = built.loadBody
      fieldsOf = bindSym"fieldsOf"
      headlessFields = bindSym"headlessFields"
      fromSorted = bindSym"fromSorted"
    recList = built.recList
    methods = quote do:
      proc `fill`(`selfL`: `T`, `fieldsL`: BDict) =
        `loadBody`

      method moldFields(`selfM`: `T`): BDict =
        var `fieldsM` = newSeqOfCap[Entry[Value, Value]](`n`)
        `moldBody`
        `fromSorted`(`fieldsM`)

      method moldHeadless(`selfHeadlessM`: `T`): Value =
        initDict(`selfHeadlessM`.moldFields)

      method mold(`selfMold`: `T`): Value =
        initRec(@[`sym`(`head`), initDict(`selfMold`.moldFields)],
                mark = `mark`)

      method loadHeadless(`selfHeadless`: `T`, `vHeadless`: Value) =
        `fill`(`selfHeadless`, `headlessFields`(`vHeadless`, `head`))

      method load(`selfLoad`: `T`, `v`: Value) =
        `fill`(`selfLoad`, `fieldsOf`(`v`, `head`, `mark`))
  else:
    let
      fs = positionalFields(f, description)
      src = genSym(nskParam, "src")
      off = genSym(nskParam, "off")
      built = buildPositional(fs, selfL, src, off)
      loadBody = built.loadBody
      items = genSym(nskVar, "items")
      itemsMold = genSym(nskVar, "items")
      moldBody = positionalMold(fs, selfM, items)
      moldBodyHeaded = positionalMold(fs, selfMold, itemsMold)
      itemsOf = bindSym"itemsOf"
      headlessItems = bindSym"headlessItems"
      headlessFields = bindSym"headlessFields"
      fromSorted = bindSym"fromSorted"
      fillNamed = genSym(nskProc, "fillNamed")
      selfN = genSym(nskParam, "self")
      fieldsN = genSym(nskVar, "fields")
      selfNL = genSym(nskParam, "self")
      fieldsNL = genSym(nskParam, "fields")
      selfPos = genSym(nskParam, "self")
    var named = newBDict()
    for (name, t) in fs:
      named[sym(name)] = t
    let
      byName = buildMoldable(named, selfN, fieldsN, selfNL, fieldsNL,
                             desc[0].text, exact, description)
      namedMold = byName.moldBody
      namedLoad = byName.loadBody
    recList = built.recList
    methods = quote do:
      proc `fill`(`selfL`: `T`, `src`: Buffer[Value], `off`: int) =
        `loadBody`

      proc `fillNamed`(`selfNL`: `T`, `fieldsNL`: BDict) =
        `namedLoad`

      method moldFields(`selfN`: `T`): BDict =
        var `fieldsN` = newSeqOfCap[Entry[Value, Value]](`n`)
        `namedMold`
        `fromSorted`(`fieldsN`)

      method positional(`selfPos`: `T`): bool =
        true

      method moldHeadless(`selfM`: `T`): Value =
        var `items` = newSeqOfCap[Value](`n`)
        `moldBody`
        initList(`items`)

      method mold(`selfMold`: `T`): Value =
        var `itemsMold` = newSeqOfCap[Value](`n` + 1)
        `itemsMold`.add `sym`(`head`)
        `moldBodyHeaded`
        initRec(`itemsMold`, mark = `mark`)

      method loadHeadless(`selfHeadless`: `T`, `vHeadless`: Value) =
        if `vHeadless`.isKind(bDict) and not `vHeadless`.mark:
          `fillNamed`(`selfHeadless`, `headlessFields`(`vHeadless`, `head`))
        else:
          `fill`(`selfHeadless`,
                 `headlessItems`(`vHeadless`, `head`, `n`, `exactLit`), 0)

      method load(`selfLoad`: `T`, `v`: Value) =
        `fill`(`selfLoad`, `itemsOf`(`v`, `head`, `mark`, `n`, `exactLit`), 1)

  let objTy = newTree(nnkObjectTy,
    newEmptyNode(),
    newTree(nnkOfInherit, bindSym"Moldable"),
    recList)
  result.name = name
  result.typeDef = newTree(nnkTypeDef, postfix(T, "*"), newEmptyNode(),
                           newTree(nnkRefTy, objTy))
  result.methods = quote do:
    proc head*(_: type `T`): Value =
      `sym`(`head`)

    method head(`selfHead`: `T`): Value =
      `sym`(`head`)

    proc marked*(_: type `T`): bool =
      `mark`

    method marked(`selfMarked`: `T`): bool =
      `mark`

    `methods`

macro moldableFrom(text: static[string], description: untyped): untyped =
  ## `moldable` given the description's text, and the expression it came
  ## from to point at when refusing it
  if text.strip.len == 0:
    error("the description is empty; a staticRead of a file that is " &
          "not there reads as empty", description)
  let desc =
    try: readValue(text)
    except ReadError as e:
      error("not a description: " & e.msg, description)
  var
    descs: seq[Value]
    types = newTree(nnkTypeSection)
    methods = newStmtList()
    names: seq[string]
  if desc.isKind(bSet):
    if desc.mark:
      error("mark each description in the set, not the set", description)
    for each in desc.els: descs.add each
  else:
    descs.add desc
  for each in descs:
    let (name, typeDef, ms) = moldDef(each, description)
    if name in names:
      error(name & " is described twice", description)
    names.add name
    types.add typeDef
    methods.add ms
  newStmtList(types, methods)

macro moldable*(description: untyped): untyped =
  ## `moldable "(HEAD {FIELD: TYPE …})"` declares HEAD, a Moldable with
  ## those fields, written as and read from `(HEAD {FIELD: VALUE …})`,
  ## marked when the description is: `!(HEAD {…})` molds `!(HEAD {…})`;
  ## `(HEAD ALIAS {…})` names the type ALIAS instead, for a HEAD that is
  ## not a Nim identifier or another reading of the same head.
  ## A TYPE naming a kind holds a value of that kind, marked when the
  ## TYPE is (`dict!`) and unmarked when it is not: a number as a BNum,
  ## text and symbol as a string, bytes as a seq[byte], a list or record
  ## as a seq[Value] (a record's head first), a dict as a BDict and a set
  ## as a BSet, each the object's own copy. `value` holds a Value of any
  ## kind, marked as the TYPE is, and `any` a Value of any kind, marked
  ## or not. Any other name is another Moldable, written by its `mold`
  ## and read by its `load`.
  ##
  ## A TYPE may also be a typed collection, marked or not: `[T]`, `(T)`
  ## and `{T}` are held as a seq of T, `{K: V}` as a seq of (key, val);
  ## each member is written and read as its TYPE, and a set or dict
  ## refuses to be written holding one twice.
  ##
  ## A field's TYPE may be `(optional T)`, held as an Option[T]: none is
  ## written by leaving the field out, and a field left out reads as
  ## none.
  ##
  ## `(HEAD ALIAS? [(NAME TYPE) …])` describes the fields by position
  ## instead: written as and read from `(HEAD VALUE …)`, each field the
  ## item at its place, and the headless form is the items as a list.
  ## Items past the last described are left behind; none can be
  ## optional. Its fields still have names: `moldFields` gives them by
  ## name, and `loadHeadless` reads them by name from a dict as well as
  ## by place from a list, so `convert` and Poly go between the two
  ## kinds of description by name.
  ##
  ## `exact` after the fields reads exactly: a field or item more than
  ## described is refused rather than left behind, as where a signature
  ## covers the value and what rode along would go unsigned. And two more
  ## TYPEs: `(bytes N)`, exactly N bytes, held as an array[N, byte], and
  ## `(one-of SYMBOL …)`, one of those symbols, held as a string. The
  ## type and its fields are public.
  ##
  ## `moldable "{(HEAD ALIAS? {…}) …}"` declares each in one type
  ## section, so they may name each other.
  ##
  ## The description is any string known while compiling: a literal, a
  ## const, or `staticRead "types.bl"`.
  newCall(bindSym"moldableFrom", description, description)

when isMainModule:
  import std/os
  let demoPath = getTempDir() / "mold-demo.bl"
  moldable """{
    (shelf Shelf {
      name: text
      size: number
      seal: bytes
      files: {File}
      meta: any
      tags: set
      something: value
      call: record
      path: symbol
      last: any
      parts: list})
    (file File {path: symbol last: any})
  }"""

  let shelf = Shelf(
    name: "top", size: 1234, seal: @[1,2,3,4],
    something: "hello".sym, 
    files: @[
      File(path: demoPath)
    ],
    last: null(true),
    path: demoPath,
    meta: rv"{a: 1}", 
    tags: rv"{x y}".els, 
    call: @[sym"go", num 1]
  )
  doAssert shelf.mold == %>Shelf.load(shelf.mold)

  for bad in ["(file {path: foo})", "!(file {path: \"foo\"})",
              "!(file {path: foo!})", "!(file {path: foo more: 1})",
              "!(file {})", "!(Other {path: foo})", "!(file !{path: foo})"]:
    try:
      let f = File.load(rv bad)
      echo "read: ", %>f
    except MoldError, ValueError:
      echo "refused ", bad, ": ", getCurrentExceptionMsg()