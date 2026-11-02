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
    mark: bool
    sigil: char
      ## what stands in for a part, by name: '$' a splice in bl or a hole
      ## in a pattern, '@' a spread, '&' a rest, and '\0' for none
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

proc spliced(sigil: char, name = Letters + Digits + {'_', '.'}): TextParser[Lit] =
  (ch(sigil) & chars(name, "name").plus.flatten).map(
    (m: (char, string)) => Lit(sigil: sigil, splice: m[1]))

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
  when v is ref:
    result = new T
    result[] = v[]
  else:
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
      if m.sigil == '@':
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
    @[spliced('$'), spliced('@')]).complete.resolve
  let read = reader.parse(text)
  if not read.isSuccess:
    error "not a value: " & text
  result = read.value
  if result.sigil == '@':
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

# ================
# Patterns
# ================

proc slotOf[T](v, key: T): int =
  ## where key stands in a dict or a set, found by bisecting: the slot of
  ## the value under it in a dict, of the member itself in a set, and -1
  ## when it is absent
  mixin cmp, kind, len, getChild
  let step = if v.kind == bDict: 2 else: 1
  var (lo, hi) = (0, v.len div step)
  while lo < hi:
    let
      mid = (lo + hi) div 2
      order = cmp(v.getChild(mid * step), key)
    if order == 0:
      return mid * step + step - 1
    if order < 0: lo = mid + 1 else: hi = mid
  -1

proc restOf[T](v: T, start: int): seq[T] =
  ## a list's or a record's members from start on
  mixin len, getChild
  result = newSeqOfCap[T](max(v.len - start, 0))
  for i in start ..< v.len:
    result.add v.getChild(i)

proc plain(l: Lit): bool =
  ## whether l holds no hole, rest or splice
  if l.sigil != '\0':
    return false
  for m in l.members:
    if not m.plain:
      return false
  true

type Fitting = object
  ## what fitting a branch's pattern makes
  src, builder: NimNode
    ## the pattern's text, for errors, and what builds its keys
  checks: seq[NimNode]
    ## what the subject must pass, in order
  binds: seq[(string, NimNode)]
    ## each hole's name and what it reads
  slots: seq[NimNode]
    ## where a dict's keys were found, declared before the branches

proc bindTo(f: var Fitting, l: Lit, read: NimNode) =
  ## binds the hole or rest l to what read reads, and $_ or &_ to nothing
  if l.splice == "_":
    return
  let name = nimSpelling(l.splice, f.src)
  for (bound, _) in f.binds:
    if bound == name:
      error(l.sigil & l.splice & " is bound twice", f.src)
  f.binds.add (name, read)

proc fit(f: var Fitting, pat: Lit, at: NimNode, anyMark: bool) =
  ## the checks the value at reads must pass to fit pat, whatever its own
  ## mark if anyMark, and the holes it binds. A frame's checks come before
  ## its members', so a member is only read from a frame known to hold it
  let mark =
    if anyMark: bindSym"anyMark"
    elif pat.mark: bindSym"marked"
    else: bindSym"unmarked"
  case pat.sigil
  of '$':
    if pat.mark:
      f.checks.add newDotExpr(at, ident"mark")
    f.bindTo(pat, at)
    return
  of '&':
    error("a rest, &" & pat.splice & ", goes last in a list or record", f.src)
  of '@':
    error("@" & pat.splice & " spreads, and a pattern takes a rest, &" & pat.splice, f.src)
  else:
    discard
  let
    isKind = bindSym"isKind"
    kind = newLit(pat.kind)
  case pat.kind
  of bList, bRec:
    let
      rest = pat.members.len > 0 and pat.members[^1].sigil == '&'
      n = pat.members.len - ord(rest)
      wide = if rest: ident">=" else: ident"=="
    f.checks.add quote do:
      `isKind`(`at`, `kind`, `mark`) and `wide`(`at`.len, `n`)
    for i in 0 ..< n:
      f.fit(pat.members[i], newCall(ident"getChild", at, newLit(i)), false)
    if rest:
      if pat.members[^1].mark:
        error("a rest carries no mark: &" & pat.members[^1].splice, f.src)
      f.bindTo(pat.members[^1], newCall(bindSym"restOf", at, newLit(n)))
  of bDict:
    f.checks.add quote do:
      `isKind`(`at`, bDict, `mark`)
    for i in countup(0, pat.members.len - 1, 2):
      if not pat.members[i].plain:
        error("a hole in a dict's key", f.src)
      let
        slot = genSym(nskVar, "slot")
        key = pat.members[i].code(f.builder)
        slotOf = bindSym"slotOf"
      f.slots.add slot
      f.checks.add quote do:
        (`slot` = `slotOf`(`at`, `key`); `slot` >= 0)
      f.fit(pat.members[i + 1], newCall(ident"getChild", at, slot), false)
  of bSet:
    if not pat.plain:
      error("a hole in a set", f.src)
    f.checks.add quote do:
      `isKind`(`at`, bSet, `mark`)
    for m in pat.members:
      let
        member = m.code(f.builder)
        slotOf = bindSym"slotOf"
      f.checks.add quote do:
        `slotOf`(`at`, `member`) >= 0
  # an atom is compared by what it holds, so none is built to compare with
  of bNum:
    let (held, numStr) = (newLit(pat.payload), bindSym"numStr")
    f.checks.add quote do:
      `isKind`(`at`, bNum, `mark`) and `numStr`(`at`) == `held`
  of bText, bSym, bBytes:
    let
      held = newLit(pat.payload)
      read = ident(
        case pat.kind
        of bText: "textVal"
        of bSym: "symVal"
        else: "bytesVal")
    f.checks.add quote do:
      `isKind`(`at`, `kind`, `mark`) and `at`.`read` == `held`
  of bNil:
    f.checks.add quote do:
      `isKind`(`at`, bNil, `mark`)

proc readPattern(src: NimNode): (Lit, bool) =
  ## a branch's pattern, and whether its options let it fit any mark
  let
    name = Letters + Digits + {'_', '-'}
    reader = basslineForm[Lit, LitBuilder](LitBuilder(),
      @[spliced('$', name), spliced('&', name), spliced('@', name)]).star.complete.resolve
    read = reader.parse(src.strVal)
  if not read.isSuccess or read.value.len notin 1 .. 2:
    error("a pattern, then its options if it has any", src)
  result = (read.value[0], false)
  if read.value.len == 2:
    let options = read.value[1]
    if options.kind != bSet or options.mark or not options.plain:
      error("a pattern's options are a set, as {any-mark}", src)
    for o in options.members:
      if o.kind == bSym and not o.mark and o.payload == "any-mark":
        result[1] = true
      else:
        error("matchValue has no option but any-mark", src)

macro matchValue*(subject: untyped, branches: varargs[untyped]): untyped =
  ##[
    Tries each branch's pattern against `subject` in turn and runs the
    first that fits, with its holes bound by `let`. A pattern is read as
    `bl` reads its text. `$name` is a hole, spelled as `blet` spells a
    name, so `$first-one` binds firstOne. `$name!` is a hole only a
    marked value fits, and `$_` fits anything and binds nothing.
    `&name`, last in a list or a record, is a rest, bound to the members
    after those before it as a seq of the subject's type, and `&_` binds
    none. A branch may name a Nim value instead of a pattern, as
    `of ping:` for a name `blet` binds, and fits a subject equal to it.
    `elif` and `else` branches go in among them as in an `if`.

    A list or record fits one of its kind, mark and length whose
    members fit in order, or with a rest one at least as long as the
    members before it. A dict fits one of its mark holding each of its
    keys, with a value that fits, and a set one holding each of its
    members, whatever else either holds. An atom fits an equal one.
    Holes go anywhere but in a dict's keys or in a set. The subject is
    read only through `Walkable`, so any value type can be matched, and
    a dict's keys and a set's members are built with the subject's type.

    A pattern may be followed by its options, a set. With {any-mark}
    the value fits whatever its own mark, so "(q $a) {any-mark}" fits
    (q 1) and !(q 1). What it holds fits as written.

    matchValue is a statement, or an expression when it ends in an
    `else` or in a pattern that fits anything after another branch.

      matchValue v:
      of "!(serve-tcp $port)": echo "serving on ", port
      of "!(connect-tcp $host $port)": echo "dialling ", host
      else: discard
  ]##
  let
    subjectSym = genSym(nskLet, "subject")
    builder = genSym(nskLet, "b")
    tries = newTree(nnkIfStmt)
  var slots: seq[NimNode]
  for i, b in branches:
    case b.kind
    of nnkOfBranch:
      if b.len != 2:
        error("one pattern a branch", b)
      if b[0].kind notin {nnkStrLit, nnkTripleStrLit, nnkRStrLit}:
        # a Nim value, which the subject fits by being equal to it
        tries.add newTree(nnkElifBranch, infix(subjectSym, "==", b[0]), b[1])
        continue
      let (pattern, anyMark) = readPattern(b[0])
      var f = Fitting(src: b[0], builder: builder)
      f.fit(pattern, subjectSym, anyMark)
      slots.add f.slots
      let body = newStmtList()
      for (name, at) in f.binds:
        body.add newLetStmt(ident(name), at)
      body.add b[1]
      if f.checks.len == 0 and tries.len > 0 and i == branches.len - 1:
        # anything fits, as an else does
        tries.add newTree(nnkElse, body)
      elif f.checks.len == 0:
        # an if begins with a condition, and nothing after this is tried
        tries.add newTree(nnkElifBranch, newLit(true), body)
      else:
        var fits = f.checks[0]
        for check in f.checks[1 .. ^1]:
          fits = infix(fits, "and", check)
        tries.add newTree(nnkElifBranch, fits, body)
    of nnkElifBranch, nnkElse:
      tries.add b
    else:
      error("matchValue takes of, elif and else branches", b)
  result = newStmtList(newLetStmt(subjectSym, subject))
  result.add quote do:
    let `builder` {.used.} = ByType[typeof(`subjectSym`)]()
  for slot in slots:
    result.add quote do:
      var `slot`: int
  result.add tries

template useValue*(V: typedesc) =
  ##[
    Gives a module its own `bl`, `blet` and `record` for values of type
    V, as `refuseWith` gives it `refuse`:

      useValue Val

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