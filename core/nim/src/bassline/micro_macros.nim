import std/[macros, sequtils, strutils]
import petit_parser
import ./[micro, text]

refuseWith BasslineError

# ================
# Sigils
# ================

type
  SigilKind = enum
    Splice, Spread, Rest

  Sigil = ref object of Live
    kind: SigilKind
    name: string
    mark: bool

const SigilChars: array[SigilKind, char] = ['$', '@', '&']

func spelling(s: Sigil): string =
  SigilChars[s.kind] & s.name

func sigilOf(n: Node): Sigil =
  case n
  of Bound(l): Sigil(l)
  of Plain: nil

func isSpread(n: Node): bool =
  let s = n.sigilOf
  not s.isNil and s.kind == Spread

func trailingRest(v: Value): Sigil =
  if v.len > 0:
    let s = v.vseq[^1].sigilOf
    if not s.isNil and s.kind == Rest:
      return s

proc readSigils(root: var Node) =
  proc isSigil(v: Value): bool =
    v.kind == bSym and v.vstr.len > 1 and v.vstr[0] in SigilChars

  proc read(n: var Node) =
    let (text, mark) = (n.asValue.vstr, n.asValue.mark)
    if text[1] == text[0]:
      # a doubled sigil spells the symbol with one
      n.asValue.vstr = text[1 .. ^1]
    else:
      let kind = SigilKind(SigilChars.find(text[0]))
      n = Sigil(kind: kind, name: text[1 .. ^1], mark: mark).toNode

  root.rewrite(isSigil, read)

proc nimSpelling(name: string): string =
  var upper = false
  for c in name:
    if c == '-':
      upper = true
    elif upper:
      result.add c.toUpperAscii
      upper = false
    else:
      result.add c
  guard result.validIdentifier, name & " has no spelling as a Nim name"

proc toNim(s: Sigil): NimNode =
  s.name.split('.').mapIt(it.nimSpelling).join(".").parseExpr

# ================
# Building
# ================

proc codegen(n: Node): NimNode

proc codegenMembers(v: Value): NimNode =
  var spreads = false
  for m in v.members:
    spreads = spreads or m.isSpread
  if not spreads:
    result = nnkBracket.newTree
    for m in v.members:
      result.add m.codegen
    return prefix(result, "@")
  let
    members = genSym(nskVar, "members")
    node = bindSym"Node"
  result = newStmtList(quote do:
    var `members`: seq[`node`])
  for m in v.members:
    if m.isSpread:
      let
        s = m.sigilOf
        (x, each) = (genSym(nskForVar, "x"), s.toNim)
        one = if s.mark: newCall(bindSym"!", x) else: x
      result.add quote do:
        for `x` in `each`:
          `members`.add `one`
    else:
      let one = m.codegen
      result.add quote do:
        `members`.add `one`
  result.add members
  result = newBlockStmt(result)

proc codegen(v: Value): NimNode =
  let mark = newLit(v.mark)
  case v.kind
  of bNil:
    newCall(bindSym"Null", mark)
  of bNum:
    let n = if v.vnum.isInt: newLit(v.vnum.asInt) else: newLit($v.vnum)
    newCall(bindSym"Num", n, mark)
  of bText:
    newCall(bindSym"Text", newLit(v.vstr), mark)
  of bSym:
    newCall(bindSym"Sym", newLit(v.vstr), mark)
  of bBytes:
    newCall(bindSym"Bytes", newLit(v.vstr), mark)
  of bList:
    newCall(bindSym"List", v.codegenMembers, mark)
  of bRec:
    newCall(bindSym"Rec", v.codegenMembers, mark)
  of bDict:
    var entries = nnkBracket.newTree
    for key, val in v.vdict.pairs:
      entries.add nnkTupleConstr.newTree(key.codegen, val.codegen)
    newCall(bindSym"Dict", prefix(entries, "@"), mark)
  of bSet:
    newCall(bindSym"Set", v.codegenMembers, mark)

proc codegen(n: Node): NimNode =
  case n
  of Plain(v):
    v.codegen
  of Bound(l):
    let s = Sigil(l)
    case s.kind
    of Splice:
      if s.mark: newCall(bindSym"!", s.toNim) else: s.toNim
    of Spread:
      refuse "a spread, " & s.spelling & ", stands only among a list's, record's or set's members"
    of Rest:
      refuse "a rest, " & s.spelling & ", stands only in a pattern"

proc placed(n, at: NimNode): NimNode =
  # so a node made by a macro is reported at the line of the macro that made it
  n.copyLineInfo(at)
  for each in n:
    discard each.placed(at)
  n

proc readValue(text: string): Node =
  var read = basslineParser().parse(text)
  guard read.isSuccess, read.message
  result = read.take
  result.readSigils

macro bl*(text: string): untyped =
  try:
    result = text.strVal.readValue.codegen.placed(text)
  except BasslineError as e:
    error(e.msg, text)

macro blet*(text: string, exported: static bool = true): untyped =
  result = newStmtList()
  try:
    let v = text.strVal.readValue.asValue
    var named: seq[(Node, Node)]
    case v.kind
    of bDict:
      for key, val in v.vdict.pairs:
        named.add (key, val)
    of bSet:
      for each in v.vset:
        named.add (each, each)
    else:
      refuse "blet takes a set of symbols or a dict from symbols to values"
    for (key, val) in named:
      guard key.isPlain and key.asValue.kind == bSym, "blet names only by symbols"
      let
        spelled = key.asValue.vstr.nimSpelling
        name = if exported: postfix(ident(spelled), "*") else: ident(spelled)
        held = genSym(nskLet, spelled)
      result.add newLetStmt(held, val.codegen)
      result.add quote do:
        template `name`(): untyped = `held`
  except BasslineError as e:
    error(e.msg, text)
  result = result.placed(text)

# ================
# Matching
# ================

type MarkTest = enum
  unmarked, marked, eitherMark

template valueOf(x: Node | Value): untyped =
  when x is Node: x.asValue else: x

func isKind(v: Value, kind: Kind, test: MarkTest): bool =
  v.kind == kind and (test == eitherMark or v.mark == (test == marked))

func isKind(n: Node, kind: Kind, test: MarkTest): bool =
  n.isPlain and n.asValue.isKind(kind, test)

func isMarked(v: Value): bool =
  v.mark

func isMarked(n: Node): bool =
  n.isPlain and n.asValue.mark

func slotOf(dict: Value, key: Node): int =
  var (lo, hi) = (0, dict.len div 2)
  while lo < hi:
    let
      mid = (lo + hi) div 2
      order = cmp(dict.nth(mid * 2), key)
    if order == 0:
      return mid * 2 + 1
    if order < 0: lo = mid + 1 else: hi = mid
  -1

func restFrom(v: Value, start: int): seq[Node] =
  v.vseq[start .. ^1]

type Fitting = object
  checks: seq[NimNode]
  binds: seq[(string, NimNode)]
  slots: seq[NimNode]

proc bindTo(f: var Fitting, s: Sigil, read: NimNode) =
  if s.name == "_":
    return
  let name = s.name.nimSpelling
  for (bound, _) in f.binds:
    guard bound != name, s.spelling & " is bound twice"
  f.binds.add (name, read)

proc fit(f: var Fitting, pattern: Node, at: NimNode, anyMark: bool) =
  case pattern
  of Bound(l):
    let s = Sigil(l)
    case s.kind
    of Splice:
      if s.mark:
        f.checks.add newCall(bindSym"isMarked", at)
      f.bindTo(s, at)
    of Spread:
      refuse s.spelling & " spreads, and a pattern takes a rest, &" & s.name
    of Rest:
      refuse "a rest, " & s.spelling & ", goes last in a list or record"
  of Plain(v):
    let
      held = newCall(bindSym"valueOf", at)
      test =
        if anyMark: bindSym"eitherMark"
        elif v.mark: bindSym"marked"
        else: bindSym"unmarked"
    f.checks.add newCall(bindSym"isKind", at, newLit(v.kind), test)
    case v.kind
    of bNil:
      discard
    of bNum:
      let n = if v.vnum.isInt: newLit(v.vnum.asInt) else: newLit($v.vnum)
      f.checks.add newCall(bindSym"==", newDotExpr(held, ident"vnum"), newCall(bindSym"initNum", n))
    of bText, bSym, bBytes:
      f.checks.add newCall(bindSym"==", newDotExpr(held, ident"vstr"), newLit(v.vstr))
    of bList, bRec:
      let
        rest = v.trailingRest
        width = if rest.isNil: v.len else: v.len - 1
        op = if rest.isNil: "==" else: ">="
      f.checks.add infix(newCall(bindSym"len", held), op, newLit(width))
      for i in 0 ..< width:
        f.fit(v.vseq[i], newCall(bindSym"nth", held, newLit(i)), false)
      if not rest.isNil:
        guard not rest.mark, "a rest carries no mark: " & rest.spelling
        f.bindTo(rest, newCall(bindSym"restFrom", held, newLit(width)))
    of bDict:
      for key, val in v.vdict.pairs:
        guard key.isPure, "a hole in a dict's key"
        let
          slot = genSym(nskVar, "slot")
          found = newCall(bindSym"slotOf", held, key.codegen)
        f.slots.add slot
        f.checks.add quote do:
          (`slot` = `found`; `slot` >= 0)
        f.fit(val, newCall(bindSym"nth", held, slot), false)
    of bSet:
      guard v.isPure, "a hole in a set"
      for m in v.members:
        f.checks.add newCall(bindSym"contains", held, m.codegen)

proc readPattern(text: string): (Node, bool) =
  var read = basslineDocument().parse(text)
  guard read.isSuccess, read.message
  var values = read.take
  guard values.len in 1 .. 2, "a pattern, then its options if it has any"
  result[0] = values[0]
  result[0].readSigils
  if values.len == 2:
    let options = values[1].asValue
    guard options.kind == bSet and not options.mark, "a pattern's options are a set, as {any-mark}"
    for o in options.members:
      guard o == Sym("any-mark"), "matchValue has no option but any-mark"
      result[1] = true

macro matchValue*(subject: untyped, branches: varargs[untyped]): untyped =
  result = newStmtList()
  var subjectSym = subject
  if subject.kind notin {nnkIdent, nnkSym}:
    # a named subject is read where it is, since binding it again can copy it
    subjectSym = genSym(nskLet, "subject")
    result.add newLetStmt(subjectSym, subject)
  let tries = newTree(nnkIfStmt)
  for i, branch in branches:
    case branch.kind
    of nnkElifBranch, nnkElse:
      tries.add branch
    of nnkOfBranch:
      if branch.len != 2:
        error("one pattern a branch", branch)
      let (pattern, body) = (branch[0], branch[1])
      if pattern.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        tries.add newTree(nnkElifBranch, newCall(bindSym"==", subjectSym, pattern), body)
        continue
      var f: Fitting
      try:
        let (read, anyMark) = pattern.strVal.readPattern
        f.fit(read, subjectSym, anyMark)
      except BasslineError as e:
        error(e.msg, pattern)
      for slot in f.slots:
        result.add newVarStmt(slot, newLit(0))
      let bound = newStmtList()
      for (name, read) in f.binds:
        bound.add newLetStmt(ident(name), read)
      bound.add body
      if f.checks.len == 0 and tries.len > 0 and i == branches.len - 1:
        tries.add newTree(nnkElse, bound)
      else:
        let fits =
          if f.checks.len == 0: newLit(true)
          else: f.checks.foldl(infix(a, "and", b))
        tries.add newTree(nnkElifBranch, fits, bound)
    else:
      error("matchValue takes of, elif and else branches", branch)
  result.add tries
