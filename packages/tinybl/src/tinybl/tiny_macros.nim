import std/[macros, algorithm, strutils, sugar]
import ./[ce, values, text]

refuseWith BasslineError

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
  guard kind in {bSet, bDict}, "ordered should only be used with bSet / bDict"
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

proc markedAs*[T](v: sink T, mark: bool): T =
  mixin setMark
  result = v
  result.setMark(mark)

type
  SubstKind = enum skSplice, skSpread, skRest

# a symbol in bl, blet or a pattern standing for Nim: `$x` splices x, or
# is a hole in a pattern, `@xs` spreads xs into the frame it stands in,
# and `&rest`, last in a pattern's list or record, binds the members
# after. A sigil doubled, `$$x`, spells the symbol `$x`
layer Subst(name: string, kind: SubstKind)

const Sigils = {'$', '@', '&'}

proc readSubst(v: Val): Subst {.reader.} =
  if v.kind != bSym or v.text.len < 2 or v.text[0] notin Sigils or
      v.text[1] == v.text[0]:
    return nil
  let kind =
    case v.text[0]
    of '$': skSplice
    of '@': skSpread
    else: skRest
  newSubst(v.text[1 .. ^1], kind)

proc sigil(s: Subst): char =
  case s.kind
  of skSplice: '$'
  of skSpread: '@'
  of skRest: '&'

proc spelled(v: Val): string =
  ## what v holds, a symbol's doubled sigil halved
  result = v.payload
  if v.kind == bSym and result.len >= 2 and result[0] in Sigils and
      result[1] == result[0]:
    result = result[1 .. ^1]

proc readVal(text: string, src: NimNode = nil): Val =
  try:
    Val.parse(text)
  except CatchableError as e:
    error("not a value: " & text & ", " & e.msg, src)

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

proc nim(s: Subst, at: NimNode): NimNode =
  ## the Nim s names, `$file-entry` fileEntry and `$p.x` p's field x
  var parts: seq[string]
  for part in s.name.split('.'):
    parts.add nimSpelling(part, at)
  parseExpr(parts.join("."))

proc codeFor(v: Val, b: NimNode, src: NimNode = nil): NimNode =
  ## what builds v with the builder b, its substitutions read from Nim
  let
    (kind, mark) = (newLit(v.kind), newLit(v.mark))
    sub = v.attach(Subst)
  if not sub.isNil:
    case sub.kind
    of skSplice:
      result = newCall(bindSym"splice", b, sub.nim(src))
      if v.mark:
        result = newCall(bindSym"withMark", result)
      return
    of skSpread:
      error("a spread, @" & sub.name & ", stands only in a frame", src)
    of skRest:
      error("a rest, &" & sub.name & ", stands only in a pattern", src)
  case v.kind
  of bNil:
    newCall(ident"buildNull", b, mark)
  of bNum .. bBytes:
    newCall(ident"buildAtom", b, newLit(v.spelled), kind, mark)
  of bList .. bSet:
    let members = genSym(nskVar, "members")
    var built = newStmtList(quote do:
      var `members` = newSeq[typeof(buildNull(`b`, false))]())
    for m in v.children:
      let spread = m.attach(Subst)
      if not spread.isNil and spread.kind == skSpread:
        let (x, each) = (genSym(nskForVar, "x"), spread.nim(src))
        var one = newCall(bindSym"splice", b, x)
        if m.mark:
          one = newCall(bindSym"withMark", one)
        built.add quote do:
          for `x` in `each`:
            `members`.add `one`
      else:
        let one = m.codeFor(b, src)
        built.add quote do:
          `members`.add `one`
    if v.kind in {bList, bRec}:
      built.add newCall(ident"buildFrame", b, members, kind, mark)
    else:
      built.add newCall(bindSym"ordered", b, members, kind, mark)
    newBlockStmt(built)

macro bl*(b: untyped, text: static string): untyped =
  ## the value text spells, built by b, a builder or a type that builds
  ## itself
  let builder = genSym(nskLet, "b")
  newBlockStmt(newStmtList(
    newLetStmt(builder, quote do: ByType[`b`]()),
    readVal(text, b).codeFor(builder, b)))

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
    v = readVal(text, V)
    builder = genSym(nskLet, "b")
  var named: seq[(Val, Val)]
  case v.kind
  of bSet:
    for each in v.children: named.add (each, each)
  of bDict:
    for i in countup(0, v.len - 1, 2):
      named.add (v.getChild(i), v.getChild(i + 1))
  else:
    error("blet takes a set of symbols or a dict from symbols to values: " & text, V)
  result = newStmtList(newLetStmt(builder, quote do: ByType[`V`]()))
  for (key, val) in named:
    if key.kind != bSym or not key.attach(Subst).isNil:
      error("blet names only by symbols: " & text, V)
    let
      name = ident(nimSpelling(key.spelled, V))
      held = genSym(nskLet, key.spelled)
      shown = if exported: postfix(name, "*") else: name
    result.add newLetStmt(held, val.codeFor(builder, V))
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

proc plain(v: Val): bool =
  ## whether v holds no hole, rest or splice
  if not v.attach(Subst).isNil:
    return false
  for m in v.children:
    if not m.plain:
      return false
  true

type FormKind = enum fHole, fSlots, fKeys, fAtom, fRefused

# what a value must be to fit a node of a pattern, read from the node and
# its Subst. A hole fits any value, or only a marked one when it is marked,
# and binds it. A list or record fits one of its kind and mark whose first
# `width` members fit, and no more of them unless `hole` is a rest, bound
# to those after. A dict or set fits one of its mark holding its keys or
# members, and an atom one equal to it. A node no value could fit says
# `why`, since a layer, read at run time too, holds no NimNode to refuse at
layer Constraint(form: FormKind, hole: Subst, width: int, why: string)

proc readConstraint(v: Val): Constraint {.reader.} =
  let sub = v.attach(Subst)
  if not sub.isNil:
    case sub.kind
    of skSplice:
      return newConstraint(fHole, sub, 0, "")
    of skRest:
      return newConstraint(fRefused, sub, 0,
        "a rest, &" & sub.name & ", goes last in a list or record")
    of skSpread:
      return newConstraint(fRefused, sub, 0,
        "@" & sub.name & " spreads, and a pattern takes a rest, &" & sub.name)
  case v.kind
  of bList, bRec:
    if v.len > 0:
      let
        last = v.getChild(v.len - 1)
        rest = last.attach(Subst)
      if not rest.isNil and rest.kind == skRest:
        if last.mark:
          return newConstraint(fRefused, rest, 0, "a rest carries no mark: &" & rest.name)
        return newConstraint(fSlots, rest, v.len - 1, "")
    newConstraint(fSlots, nil, v.len, "")
  of bDict:
    for i in countup(0, v.len - 1, 2):
      if not v.getChild(i).plain:
        return newConstraint(fRefused, nil, 0, "a hole in a dict's key")
    newConstraint(fKeys, nil, v.len div 2, "")
  of bSet:
    if not v.plain:
      return newConstraint(fRefused, nil, 0, "a hole in a set")
    newConstraint(fKeys, nil, v.len, "")
  else:
    newConstraint(fAtom, nil, 0, "")

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

proc bindTo(f: var Fitting, hole: Subst, read: NimNode) =
  ## binds the hole or rest to what read reads, and $_ or &_ to nothing
  if hole.name == "_":
    return
  let name = nimSpelling(hole.name, f.src)
  for (bound, _) in f.binds:
    if bound == name:
      error(hole.sigil & hole.name & " is bound twice", f.src)
  f.binds.add (name, read)

proc fit(f: var Fitting, pat: Val, at: NimNode, anyMark: bool) =
  ## the checks the value at reads must pass to fit pat, as pat's
  ## Constraint says, whatever its own mark if anyMark, and the holes it
  ## binds. A frame's checks come before its members', so a member is only
  ## read from a frame known to hold it
  let need = pat.attach(Constraint)
  if need.isNil:
    error("not a pattern", f.src)
  let
    isKind = bindSym"isKind"
    kind = newLit(pat.kind)
    mark =
      if anyMark: bindSym"anyMark"
      elif pat.mark: bindSym"marked"
      else: bindSym"unmarked"
  case need.form
  of fRefused:
    error(need.why, f.src)
  of fHole:
    if pat.mark:
      f.checks.add newDotExpr(at, ident"mark")
    f.bindTo(need.hole, at)
  of fSlots:
    let
      n = need.width
      wide = if need.hole.isNil: ident"==" else: ident">="
    f.checks.add quote do:
      `isKind`(`at`, `kind`, `mark`) and `wide`(`at`.len, `n`)
    for i in 0 ..< n:
      f.fit(pat.getChild(i), newCall(ident"getChild", at, newLit(i)), false)
    if not need.hole.isNil:
      f.bindTo(need.hole, newCall(bindSym"restOf", at, newLit(n)))
  of fKeys:
    let slotOf = bindSym"slotOf"
    f.checks.add quote do:
      `isKind`(`at`, `kind`, `mark`)
    if pat.kind == bDict:
      for i in countup(0, pat.len - 1, 2):
        let
          slot = genSym(nskVar, "slot")
          key = pat.getChild(i).codeFor(f.builder, f.src)
        f.slots.add slot
        f.checks.add quote do:
          (`slot` = `slotOf`(`at`, `key`); `slot` >= 0)
        f.fit(pat.getChild(i + 1), newCall(ident"getChild", at, slot), false)
    else:
      for m in pat.children:
        let member = m.codeFor(f.builder, f.src)
        f.checks.add quote do:
          `slotOf`(`at`, `member`) >= 0
  of fAtom:
    var atom = pat.codeFor(f.builder, f.src)
    if anyMark:
      atom = newCall(bindSym"markedAs", atom, newDotExpr(at, ident"mark"))
    f.checks.add quote do:
      `at` == `atom`

proc readPattern(src: NimNode): (Val, bool) =
  ## a branch's pattern, and whether its options let it fit any mark
  src.expectKind(nnkStrLit)
  var read: seq[Val]
  try:
    read = Val.parseMany(src.strVal)
  except CatchableError as e:
    error("not a pattern: " & e.msg, src)
  if read.len notin 1 .. 2:
    error("a pattern, then its options if it has any", src)
  result = (read[0], false)
  if read.len == 2:
    let options = read[1]
    if options.kind != bSet or options.mark or not options.plain:
      error("a pattern's options are a set, as {any-mark}", src)
    for o in options.children:
      if o.kind == bSym and not o.mark and o.text == "any-mark":
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
    Gives a module its own `bl` and `blet` for values of type V, as
    `refuseWith` gives it `refuse`:

      useValue Val

      let p = bl"(point 1 2)"
      echo bl"(line $p $p!)"

    `bl"…"` is `V.bl"…"` and `blet"…"` is `V.blet"…"`.
  ]##
  template bl(text: static string): untyped {.used.} =
    bl(V, text)

  template blet*(text: static string, exported: static bool = true): untyped {.used.} =
    blet(V, text, exported)