import std/[macros, algorithm, strutils, sugar]
import petit_parser
import ./[ce, values, text]

refuseWith BasslineError

# ================
# Records
# ================

proc buildRecordConstructor(T, V: NimNode, fieldNames: seq[NimNode], rest: NimNode): NimNode =
  ## rest is the field holding the members after the named ones, or nil
  let
    factory = ident("new")
    val = ident("val")
    res = ident("res")
    self = ident("self")
    isValid = ident("isValid")
    count = fieldNames.len

  var setters = newStmtList()

  for i, each in fieldNames:
    setters.add quote do:
      `res`.`each` = `val`.getChild(`i`)
  if rest != nil:
    setters.add quote do:
      `res`.`rest` = newSeqOfCap[`V`](`val`.len - `count`)
      for i in `count` ..< `val`.len:
        `res`.`rest`.add `val`.getChild(i)

  let fits =
    if rest == nil: quote do: `val`.len == `count`
    else: quote do: `val`.len >= `count`

  result = quote do:
    proc canFit*(`val`: `V`, _: typedesc[`T`]): bool =
      `val`.kind == bRec and `fits`

    proc `isValid`*(`self`: `T`): bool

    proc `factory`*(R: typedesc[`T`], `val`: `V`): `T` =
      ## the record val reads as, or nil when it doesn't fit
      if `val`.canFit(R):
        var `res` = R(mark: `val`.mark)
        `setters`
        if `isValid`(`res`):
          return `res`

proc buildRecordAccess(T, V: NimNode, fieldNames: seq[NimNode], rest: NimNode): NimNode =
  let
    self = ident("self")
    idx = ident("idx")
    val = ident("val")
    b = ident("b")
    getChild = ident("[]")
    setChild = ident("[]=")
    dollar = ident("$")
    count = fieldNames.len
    outside = newLit($T & " has " & $count & " fields")

  var
    getAt = newTree(nnkCaseStmt, idx)
    setAt = newTree(nnkCaseStmt, idx)
    members = newTree(nnkBracket)
    fieldStrings: seq[string] = @[]

  for i, each in fieldNames:
    getAt.add newTree(nnkOfBranch, newLit(i), newDotExpr(self, each))
    setAt.add newTree(nnkOfBranch, newLit(i),
      newAssignment(newDotExpr(self, each), val))
    members.add newDotExpr(self, each)
    fieldStrings.add each.strVal

  var
    length = newLit(count)
    held = prefix(members, "@")
  if rest == nil:
    let refused = quote do: raise newException(IndexDefect, `outside`)
    getAt.add newTree(nnkElse, refused)
    setAt.add newTree(nnkElse, refused)
  else:
    # past the named fields is the rest, which refuses an index it lacks
    getAt.add newTree(nnkElse, quote do: `self`.`rest`[`idx` - `count`])
    setAt.add newTree(nnkElse, quote do: `self`.`rest`[`idx` - `count`] = `val`)
    fieldStrings.add rest.strVal
    length = quote do: `count` + `self`.`rest`.len
    held =
      if count == 0: quote do: `self`.`rest`
      else: quote do: `held` & `self`.`rest`

  result = quote do:
    proc kind*(_: `T`): Kind =
      bRec

    proc len*(`self`: `T`): int =
      `length`

    proc `getChild`*(`self`: `T`, `idx`: int): `V` =
      `getAt`

    proc `setChild`*(`self`: `T`, `idx`: int, `val`: sink `V`) =
      `setAt`

    iterator children*(`self`: `T`): `V` =
      for i in 0..<`self`.len:
        yield `self`[i]

    iterator fields*(`self`: `T`): (int, string) =
      for i, f in `fieldStrings`:
        yield (i, f)

    proc toValue*[V; B: Builder[V]](`self`: `T`, `b`: B): V =
      ## the record as a value b builds, so it splices into bl
      `b`.buildFrame(`held`, bRec, `self`.mark)

    proc toValue*(`self`: `T`): `V` =
      `self`.toValue(ByType[`V`]())

    proc `dollar`*(`self`: `T`): string =
      if isNil(`self`): "nil"
      else: toBlText(`self`.toValue)

macro recordOf*(V: typedesc, rec: untyped, rest: varargs[untyped]): untyped =
  ##[
    A record whose fields hold values of type V: `recordOf(V, Point(x, y))`
    is a ref type Point with a mark and the fields x and y, read from a
    record of two members by `Point.new v`. The block after it, if
    there is one, is the conditions a record must meet, one a line,
    each field read by its name and the record as `self`. A last field
    written `&name`, as in `Call(h, &args)`, holds the members after the
    named ones as a seq, so `Call.new` reads a record at least as long as
    the named fields. `useValue` gives a module `record`, this
    with V said once.
  ]##
  rec.expectKind(nnkCall)
  rec.expectMinLen(2)
  rec[0].expectKind(nnkIdent)

  result = newStmtList()

  let
    typeName = rec[0]
    self = ident("self")
  var
    fieldNames: seq[NimNode]
    restName: NimNode = nil
    fields = newTree(nnkIdentDefs)

  for i, each in rec[1..^1]:
    if each.kind == nnkPrefix and each[0].eqIdent("&"):
      # &name, last, holds the members after the named ones
      if i != rec.len - 2: error("a rest goes last", each)
      each[1].expectKind(nnkIdent)
      restName = each[1]
      continue
    each.expectKind(nnkIdent)
    fieldNames.add each
    fields.add postfix(each, "*")
  fields.add(V, newEmptyNode())

  ## all record types will have a mark field
  let recList = newTree(nnkRecList,
    newTree(nnkIdentDefs, postfix(ident("mark"), "*"), bindSym"bool", newEmptyNode()))
  if fieldNames.len > 0: recList.add fields
  if restName != nil:
    recList.add newTree(nnkIdentDefs, postfix(restName, "*"),
      nnkBracketExpr.newTree(bindSym"seq", V), newEmptyNode())
  let
    objTy = newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList)
    exported = postfix(typeName, "*")
  result.add quote do:
    type `exported` = ref `objTy`

  result.add buildRecordConstructor(typeName, V, fieldNames, restName)
  result.add buildRecordAccess(typeName, V, fieldNames, restName)

  var validationBody = newStmtList()

  # each field by its own name, so a condition reads `x` for `self.x`,
  # splices in bl among them
  for each in fieldNames & (if restName == nil: @[] else: @[restName]):
    validationBody.add quote do:
      template `each`(): untyped {.used.} = `self`.`each`

  case rest.len
  of 0:
    discard
  of 1:
    let validation = rest[0]
    for each in validation.children:
      validationBody.add quote do:
        if not `each`: return false
  else:
    error("expected a stmtList / nothing", rest)

  result.add quote do:
    proc isValid*(`self`: `typeName`): bool =
      if isNil(`self`): return false
      `validationBody`
      true

type
  Lit = ref object
    ## a value read at compile time, a splice standing where its part goes
    kind: Kind
    mark, spread: bool
    payload, splice: string
    members: seq[Lit]

  LitBuilder = object

proc buildNull(b: LitBuilder, mark: bool): Lit = Lit(kind: bNil, mark: mark)
proc buildAtom(b: LitBuilder, s: sink string, kind: Kind, mark: bool): Lit =
  Lit(kind: kind, payload: s, mark: mark)
proc buildFrame(b: LitBuilder, s: sink seq[Lit], kind: Kind, mark: bool): Lit =
  Lit(kind: kind, members: s, mark: mark)
proc setMark(v: var Lit, mark: bool) = v.mark = mark
proc `==`(a, b: Lit): bool = true
proc `<`(a, b: Lit): bool = false
proc cmp(a, b: Lit): int = 0
  ## order is the running program's, so text keeps the order written.
  ## text.nim sorts a set with `sort(cmp)`, which takes system's cmp
  ## over `==` and `<`, so those say the same

proc spliced(sigil: char, spread: bool): TextParser[Lit] =
  (ch(sigil) & chars(Letters + Digits + {'_', '.'}, "name").plus.flatten).map(
    (m: (char, string)) => Lit(splice: m[1], spread: spread))

# ================
# At run time
# ================

proc bytesOf(x: openArray[byte]): string =
  result = newString(x.len)
  for i, c in x:
    result[i] = char(c)

template splice*(b, x: untyped): untyped =
  ## x as a value b builds
  mixin buildAtom, toValue
  when x is typeof(b.buildNull(false)): x
  elif x is string: b.buildAtom(x, bText, false)
  elif x is SomeInteger: b.buildAtom($x, bNum, false)
  elif compiles(bytesOf(x)): b.buildAtom(bytesOf(x), bBytes, false)
  else: x.toValue(b)

proc withMark*[T](v: sink T): T =
  mixin setMark
  result = v
  result.setMark(true)

proc ordered*[T; B: Builder[T]](b: B, members: sink seq[T], kind: Kind, mark: bool): T =
  ## a set's members, or a dict's keys and values alternating, put in CE
  ## order and built
  mixin cmp, buildFrame
  if kind == bSet:
    members.sort(cmp)
    return b.buildFrame(members, bSet, mark)
  var entries = newSeqOfCap[(T, T)](members.len div 2)
  for i in countup(0, members.len - 1, 2):
    entries.add (move members[i], move members[i + 1])
  entries.sort((x, y: (T, T)) => cmp(x[0], y[0]))
  var flat = newSeqOfCap[T](members.len)
  for e in entries.mitems:
    flat.add move e[0]
    flat.add move e[1]
  b.buildFrame(flat, bDict, mark)

# ================
# At compile time
# ================

proc code(l: Lit, b: NimNode): NimNode =
  ## what builds l with the builder b
  if l.splice.len > 0:
    result = newCall(bindSym"splice", b, parseExpr(l.splice))
    if l.mark:
      result = newCall(bindSym"withMark", result)
    return
  let (kind, mark) = (newLit(l.kind), newLit(l.mark))
  case l.kind
  of bNil:
    return newCall(ident"buildNull", b, mark)
  of bNum .. bBytes:
    return newCall(ident"buildAtom", b, newLit(l.payload), kind, mark)
  of bList .. bSet:
    let members = genSym(nskVar, "members")
    result = newStmtList(quote do:
      var `members` = newSeq[typeof(buildNull(`b`, false))]())
    for m in l.members:
      if m.spread:
        let (x, each) = (genSym(nskForVar, "x"), parseExpr(m.splice))
        var one = newCall(bindSym"splice", b, x)
        if m.mark:
          one = newCall(bindSym"withMark", one)
        result.add quote do:
          for `x` in `each`:
            `members`.add `one`
      else:
        let one = m.code(b)
        result.add quote do:
          `members`.add `one`
    if l.kind in {bList, bRec}:
      result.add newCall(ident"buildFrame", b, members, kind, mark)
    else:
      result.add newCall(bindSym"ordered", b, members, kind, mark)
    result = newBlockStmt(result)

proc markedAs*[T](v: sink T, mark: bool): T =
  mixin setMark
  result = v
  result.setMark(mark)

proc readLit(text: string): Lit =
  let reader = basslineForm[Lit, LitBuilder](LitBuilder(),
    @[spliced('$', false), spliced('@', true)]).complete.resolve
  let read = reader.parse(text)
  if not read.isSuccess:
    error "not a value: " & text
  result = read.value
  if result.spread:
    error "a spread stands only in a frame: " & text

macro bl*(b: untyped, text: static string): untyped =
  ## the value text spells, built by b, a builder or a type that builds
  ## itself
  let builder = genSym(nskLet, "b")
  newBlockStmt(newStmtList(
    newLetStmt(builder, quote do: ByType[`b`]()),
    readLit(text).code(builder)))

proc nimSpelling(name: string, at: NimNode): string =
  ## `file-entry` as a Nim identifier, fileEntry
  var upper = false
  for c in name:
    if c == '-':
      upper = true
    elif upper:
      result.add c.toUpperAscii
      upper = false
    else:
      result.add c
  if not validIdentifier(result):
    error(name & " has no spelling as a Nim name", at)

macro blet*(V: typedesc, text: static string, exported: static bool = true): untyped =
  ##[
    Names for values, built by the type V. A set of symbols names each
    symbol, `{foo bar}` binding foo to the symbol foo, and a dict names
    each value by its key, `{nums: [1 2 3]}` binding nums to that list.
    A name is spelled as a Nim one, so foo-bar is fooBar. Each value is
    built once, and its name is a template over it, so a name can also
    be a proc in the same module. The names are exported unless
    `exported` is false.
  ]##
  let
    l = readLit(text)
    builder = genSym(nskLet, "b")
  var named: seq[(Lit, Lit)]
  case l.kind
  of bSet:
    for each in l.members: named.add (each, each)
  of bDict:
    for i in countup(0, l.members.len - 1, 2):
      named.add (l.members[i], l.members[i + 1])
  else:
    error("blet takes a set of symbols or a dict from symbols to values: " & text)
  result = newStmtList(newLetStmt(builder, quote do: ByType[`V`]()))
  for (key, val) in named:
    if key.kind != bSym or key.splice.len > 0:
      error("blet names only by symbols: " & text)
    let
      name = ident(nimSpelling(key.payload, V))
      held = genSym(nskLet, key.payload)
      shown = if exported: postfix(name, "*") else: name
    result.add newLetStmt(held, val.code(builder))
    result.add quote do:
      template `shown`(): untyped = `held`

template useValue*(V: typedesc) =
  ##[
    Gives a module its own `bl`, `blet` and `record` for values of type
    V, as `refuseWith` gives it `refuse`:

      useValue ValueObj

      record Point(x, y):
        self.x.isKind(bNum, unmarked)

      let p = Point.new bl"(1 2)"
      echo bl"(line $p $p)"

    `bl"…"` is `V.bl"…"`, `blet"…"` is `V.blet"…"` and `record T(…)`
    is `recordOf(V, T(…))`. A record splices into bl as the value it
    holds.
  ]##
  template bl(text: static string): untyped {.used.} =
    bl(V, text)

  template blet*(text: static string, exported: static bool = true): untyped {.used.} =
    blet(V, text, exported)

  template record(rec: untyped): untyped {.used.} =
    recordOf(V, rec)

  template record(rec, conditions: untyped): untyped {.used.} =
    recordOf(V, rec, conditions)