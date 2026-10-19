import std/[macros, strutils]
import ./[builders, reader, shared]

refuseWith BasslineError

proc nimSpelling*(name: string, capital: bool): string =
  ## `file-entry` as a Nim identifier: FileEntry for a type, fileEntry
  ## for a field
  var upper = capital
  for c in name:
    if c == '-':
      upper = true
    elif upper:
      result.add c.toUpperAscii
      upper = false
    else:
      result.add c
  guard validIdentifier(result), name & " has no spelling as a Nim name"

proc letTerms(text: string): seq[(string, Value)] =
  let val = readValue(text)
  val.expectKind({bDict, bSet})
  case val.kind
  of bDict:
    for k, v in val.dict:
      k.expectKind(bSym)
      let name = nimSpelling(k.text, capital = false)
      result.add (name, v)
  of bSet:
    for each in val.els:
      each.expectKind(bSym)
      let name = nimSpelling(each.text, capital = false)
      result.add (name, each)
  else: refuse "blet requires a set of symbols or a dict of symbol -> value"

proc emitFmtAST(val: Value): NimNode

const Sigils = {'$', '&', '@'}

proc sigil(v: Value): char =
  ## what a symbol $NAME, &NAME or @NAME is, a hole, a rest or a spread,
  ## by its first character, and '\0' for any other value. A sigil
  ## doubled, $$NAME, is the symbol $NAME and no sigil
  if v.kind == bSym and v.text.len > 1 and v.text[0] in Sigils and
      v.text[1] != v.text[0]:
    v.text[0]
  else: '\0'

proc named(v: Value): string =
  ## the name after a symbol's sigil
  v.text[1 .. ^1]

proc spelled(v: Value): string =
  ## a symbol's text, a doubled sigil read as one
  if v.text.len > 1 and v.text[0] in Sigils and v.text[1] == v.text[0]:
    v.text[1 .. ^1]
  else: v.text

macro blet*(src: string, exported = true) =
  ##[
    Parses bassline text into a series of bindings for values

    When given a set of symbols, it binds each name to its symbol.

    ie: when given {foo bar baz} it generates, in effect:
      let foo = sym"foo"
      let bar = sym"bar"
      let baz = sym"baz"

    When given a dict with symbol keys it binds the symbol to their
    associated value.

    ie: when given {foo: [1 2 3]} it generates, in effect:
      let foo = initList([1,2,3])

    Each value is built once, into a hidden let, and the name is a
    template over it, so a name can also be a proc or method in the same
    module, such as `joined` beside the conversation hook.
  ]##
  src.expectKind({nnkStrLit, nnkTripleStrLit, nnkRStrLit})
  let
    declarations = newTree(nnkStmtList)
    isExported = exported.boolVal
  for (name, val) in letTerms(src.strVal):
    let
      nameIdent = if isExported: postfix(ident(name), "*") else: ident(name)
      held = genSym(nskLet, name)
      valLit = emitFmtAST(val)
    declarations.add(
      quote do:
        let `held` = `valLit`
        template `nameIdent`(): Value = `held`)
  result = declarations

proc emitFmtAST(val: Value): NimNode =
  ## the code that builds `val`, as it would be written by hand: an atom
  ## as a literal, a frame by its builder (newLit can't write one, it
  ## sees only the Frame a frame is held as), and $NAME as the Nim value
  ## NAME, spelled as blet spells it
  let mark = val.mark
  case val.kind
  of bSym:
    case val.sigil
    of '$':
      let spliced = ident(nimSpelling(val.named, false))
      return
        if mark: quote do: withMark(toValue(`spliced`))
        else: quote do: toValue(`spliced`)
    of '&':
      refuse "&" & val.named & " is a rest, for a matchValue pattern, and @" &
        val.named & " spreads"
    of '@': refuse "@" & val.named & " spreads into a list, record or set"
    else: return newLit(sym(val.spelled, mark))
  of bList, bRec, bSet:
    let made =
      case val.kind
      of bList: bindSym"initList"
      of bRec: bindSym"initRec"
      else: bindSym"initSet"
    var spreads = false
    for child in val.children:
      if child.sigil == '@': spreads = true
    if not spreads:
      let members = newTree(nnkBracket)
      for child in val.children:
        members.add(emitFmtAST(child))
      return
        if val.kind == bSet: newCall(made, members, newLit(mark))
        else: newCall(made, prefix(members, "@"), newLit(mark))
    # a frame with a spread in it is gathered, then made
    let
      gathered = genSym(nskVar, "members")
      value = bindSym"Value"
      build = newStmtList(quote do:
        var `gathered`: seq[`value`])
    for child in val.children:
      if child.sigil != '@':
        build.add newCall(ident"add", gathered, emitFmtAST(child))
        continue
      guard not child.mark, "a spread carries no mark: @" & child.named
      let
        spread = ident(nimSpelling(child.named, false))
        each = genSym(nskForVar, "each")
      build.add quote do:
        when `spread` is `value`:
          `spread`.expectKind({bList, bRec})
          for `each` in `spread`.items: `gathered`.add `each`
        else:
          for `each` in `spread`: `gathered`.add toValue(`each`)
    build.add newCall(made, gathered, newLit(mark))
    return newTree(nnkBlockStmt, newEmptyNode(), build)
  of bDict:
    let dictArgs = newTree(nnkBracket)
    for k, v in val.dict:
      dictArgs.add(newTree(nnkTupleConstr, emitFmtAST(k), emitFmtAST(v)))
    return quote do:
      initDict(`dictArgs`, `mark`)
  of bNum:
    # newLit would spell out a wide number's BigInt, whose fields are private
    let n = val.num
    return
      if n.isBig: newCall(bindSym"num", newLit($n), newLit(mark))
      else: newCall(bindSym"num", newLit(n.small), newLit(mark))
  else:
    return newLit(val)

macro blfmt*(src: string): untyped =
  ##[
    Reads bassline text and generates the code that builds
    that value at runtime.

    Symbols that begin with $ are treated as holes, where $name
    is the name of a nim binding of a Value. The name is spelled as blet
    spells it, so $foo-bar is fooBar. A marked hole, $name!, marks what
    goes in. In a list, record or set, @name spreads the members of
    name there, a seq or array of anything toValue takes, or a list or
    record. A sigil doubled, $$name or @@name, is the symbol $name or
    @name itself, and &name, a rest, is for matchValue.

    ie:

    let
      n = 3
      myCount = blfmt"(count $n items)"

    generates:
      initRec(@[sym"count", toValue(n), sym"items"])
  ]##
  src.expectKind({nnkStrLit, nnkTripleStrLit, nnkRStrLit})
  let val = readValue(src.strVal)
  return val.emitFmtAST

func markedAs(v: sink Value, mark: bool): Value =
  result = v
  result.mark = mark

macro blfmt*(src: string, mark: bool): untyped =
  ## the same, its mark said by `mark` at runtime, as
  ## blfmt("($kind $root)", node.mark) for a frame marked as another is.
  ## The text says no mark of its own
  src.expectKind({nnkStrLit, nnkTripleStrLit, nnkRStrLit})
  let val = readValue(src.strVal)
  guard not val.mark, "the mark is said once, by the text or by `mark`: " & src.strVal
  newCall(bindSym"markedAs", val.emitFmtAST, mark)

template bl*(src: string): untyped =
  blfmt(src)

template bl*(src: string, mark: bool): untyped =
  blfmt(src, mark)

proc plain(v: Value): bool =
  ## whether `v` holds no hole, rest or spread
  if v.sigil != '\0': return false
  for child in v.children:
    if not child.plain: return false
  true

proc binding(binds: var seq[(string, NimNode)], v: Value, read: NimNode) =
  ## binds the name of the hole or rest `v` to what `read` reads, and
  ## $_ or &_ to nothing
  if v.named == "_": return
  let name = nimSpelling(v.named, false)
  for (bound, _) in binds:
    guard bound != name, v.spelled & " is bound twice"
  binds.add (name, read)

proc fitAST(pat: Value, at: NimNode, anyMark: bool,
            checks: var seq[NimNode], binds: var seq[(string, NimNode)]) =
  ## the checks the value `at` reads passes when it fits `pat`, whatever
  ## its own mark if `anyMark`, and the holes it binds. A frame's come
  ## before its members', so a member is read as it would be by hand,
  ## only from a frame known to hold it
  let mark =
    if anyMark: bindSym"anyMark"
    elif pat.mark: bindSym"marked"
    else: bindSym"unmarked"
  case pat.sigil
  of '$':
    if pat.mark: checks.add newDotExpr(at, ident"mark")
    binds.binding(pat, at)
    return
  of '&': refuse "a rest, &" & pat.named & ", goes last in a list or record"
  of '@': refuse "@" & pat.named & " spreads, and a pattern takes a rest, &" & pat.named
  else: discard
  case pat.kind
  of bList, bRec:
    let
      kind = if pat.kind == bList: bindSym"bList" else: bindSym"bRec"
      rest = pat.len > 0 and pat.items[^1].sigil == '&'
      n = if rest: pat.len - 1 else: pat.len
    let wide = if rest: ident">=" else: ident"=="
    checks.add quote do: `at`.isKind(`kind`, `mark`) and `wide`(`at`.len, `n`)
    for i in 0 ..< n:
      let member = nnkBracketExpr.newTree(newDotExpr(at, ident"items"), newLit(i))
      fitAST(pat.items[i], member, false, checks, binds)
    if rest:
      guard not pat.items[^1].mark, "a rest carries no mark: " & pat.items[^1].spelled
      binds.binding(pat.items[^1], quote do: `at`.items.data[`n` .. ^1])
  of bDict:
    checks.add quote do: `at`.isKind(bDict, `mark`)
    for k, each in pat.dict:
      guard k.plain, "a hole in a dict's key"
      let key = emitFmtAST(k)
      checks.add quote do: `key` in `at`.dict
      fitAST(each, nnkBracketExpr.newTree(newDotExpr(at, ident"dict"), key), false, checks, binds)
  of bSet:
    guard pat.plain, "a hole in a set"
    checks.add quote do: `at`.isKind(bSet, `mark`)
    for each in pat.els:
      let member = emitFmtAST(each)
      checks.add quote do: `member` in `at`.els
  # an atom is compared by what it holds, so none is built to compare with
  of bSym, bText:
    let
      kind = if pat.kind == bSym: bindSym"bSym" else: bindSym"bText"
      spelling = newLit(if pat.kind == bSym: pat.spelled else: pat.text)
    checks.add quote do: `at`.isKind(`kind`, `mark`) and `at`.text == `spelling`
  of bNum:
    let
      n = pat.num
      held = if n.isBig: newLit($n) else: newLit(n.small)
      same = bindSym"cmpNums"
      num = bindSym"initNum"
    checks.add quote do: `at`.isKind(bNum, `mark`) and `same`(`at`.num, `num`(`held`)) == 0
  of bBytes:
    let held = newLit(pat.bytes)
    checks.add quote do: `at`.isKind(bBytes, `mark`) and `at`.bytes == `held`
  of bNil:
    checks.add quote do: `at`.isKind(bNil, `mark`)

proc patternOf(lit: NimNode): (Value, bool) =
  ## a branch's pattern, and whether its options let it fit any mark
  let read = readDocument(lit.strVal)
  if read.len notin 1 .. 2: error("a pattern, then its options if it has any", lit)
  result = (read[0], false)
  if read.len == 2:
    let options = read[1]
    if not options.isKind(bSet, unmarked):
      error("a pattern's options are a set, as {any-mark}", lit)
    for o in options.els:
      if o == sym"any-mark": result[1] = true
      else: error("matchValue has no option " & $o, lit)

macro matchValue*(subject: untyped, branches: varargs[untyped]): untyped =
  ##[
    Tries each branch's pattern against `subject` in turn and runs the
    first that fits, with its holes bound by `let`. A pattern is read
    as blfmt reads its text: $name is a hole, spelled as blet spells
    it, $name! a hole only a marked value fits, $_ fits anything and
    binds nothing. &name, last in a list or record, is a rest, bound
    to the members after those before it as a seq[Value], and &_
    binds none. A sigil doubled, $$name or &&name, is the symbol $name
    or &name. A branch may name a Nim value instead of a pattern, as
    `of ping:` for a name blet binds, and fits a subject equal to it.
    `elif` and `else` branches go in among them as in an `if`.

    A list or record fits one of its kind, mark and length whose
    members fit in order, or with a rest one at least as long as the
    members before it. A dict fits one of its mark holding each of its
    keys, with a value that fits, and a set one holding each of its
    members, whatever else either holds. An atom fits an equal one.
    Holes go anywhere but in a dict's keys or in a set. In a generic
    proc a hole named like a proc in scope, such as $first, reads as
    that proc in the body, since the body is bound before the macro
    runs, so name it otherwise.

    A pattern may be followed by its options, a set. With {any-mark}
    the value fits whatever its own mark, so "(q $a) {any-mark}" fits
    (q 1) and !(q 1). What it holds fits as written.

    matchValue is a statement, or an expression when it ends in an
    `else` or in a pattern that fits anything after another branch.

    ie:

      matchValue v:
      of "!(serve-tcp $port)": echo "serving on ", port
      of "!(connect-tcp $host $port)": echo "dialling ", host
      else: discard

    generates, for the first branch:

      if v.isKind(bRec, marked) and v.len == 2 and
          v.items[0].isKind(bSym, unmarked) and v.items[0].text == "serve-tcp":
        let port = v.items[1]
        echo "serving on ", port
  ]##
  let subjectSym = genSym(nskLet, "subject")
  let tries = newTree(nnkIfStmt)
  for i, b in branches:
    case b.kind
    of nnkOfBranch:
      if b.len != 2: error("one pattern a branch", b)
      if b[0].kind notin {nnkStrLit, nnkTripleStrLit, nnkRStrLit}:
        # a Nim value, which the subject fits by being equal to it
        tries.add newTree(nnkElifBranch, infix(subjectSym, "==", b[0]), b[1])
        continue
      var
        checks: seq[NimNode]
        binds: seq[(string, NimNode)]
      let (pattern, anyMark) = patternOf(b[0])
      fitAST(pattern, subjectSym, anyMark, checks, binds)
      let body = newStmtList()
      for (name, at) in binds: body.add newLetStmt(ident(name), at)
      body.add b[1]
      if checks.len == 0 and tries.len > 0 and i == branches.len - 1:
        tries.add newTree(nnkElse, body)  # anything fits, as an else does
      elif checks.len == 0:  # an if begins with a condition, and nothing after this is tried
        tries.add newTree(nnkElifBranch, newLit(true), body)
      else:
        var fits = checks[0]
        for check in checks[1 .. ^1]: fits = infix(fits, "and", check)
        tries.add newTree(nnkElifBranch, fits, body)
    of nnkElifBranch, nnkElse: tries.add b
    else: error("matchValue takes of, elif and else branches", b)
  result = newStmtList(newLetStmt(subjectSym, subject), tries)