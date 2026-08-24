import std/[macros, strutils]
import pkg/core
import pkg/lib/reader

export core, reader

func blSplice*[T](x: T, marked: static bool): Value =
  ## a spliced value keeps whatever mark it came with, unless the
  ## splice itself is marked
  when marked: mark(toValue(x)) else: toValue(x)

func readHex(name: string): seq[byte] =
  ## I really should put this somewhere, because I think we
  ## have like 3 of these functions in the codebase.
  ## Too bad!
  parseHexStr(name.replace("_", "")).toBytes()

# ================ THE MACRO ================

proc bad(n: NimNode, msg: string) {.noreturn.} =
  error("bl: " & msg, n)

proc identOf(n: NimNode): string =
  ## the name an ident or accent-quoted ident spells
  case n.kind
  of nnkIdent, nnkSym:
    result = n.strVal
  of nnkAccQuoted:
    for c in n:
      result.add identOf(c)
  else:
    bad(n, "not a name: " & n.repr)

proc build(n: NimNode, marked: bool): NimNode

proc frameParts(n: NimNode, first: int): (seq[NimNode], bool) =
  ## every element of a frame, and whether any of them spreads
  for i in first ..< n.len:
    let c = n[i]
    if c.kind == nnkPrefix and identOf(c[0]) == "%%":
      result[1] = true
    result[0].add c

proc buildFrame(n: NimNode, first: int, marked: bool, maker: static string): NimNode =
  ## a positional frame: the plain case is one constructor call; a
  ## frame with a spread in it is built as a draft and closed
  let (els, spreads) = frameParts(n, first)
  let mk = bindSym(maker)
  if not spreads:
    var arr = nnkBracket.newTree()
    for c in els:
      arr.add build(c, false)
    return newCall(mk, nnkPrefix.newTree(ident"@", arr), newLit(marked))
  let acc = genSym(nskVar, "els")
  var body = newStmtList(
    newVarStmt(acc, newCall(nnkBracketExpr.newTree(ident"newSeq", ident"Value")))
  )
  for c in els:
    if c.kind == nnkPrefix and identOf(c[0]) == "%%":
      let it = genSym(nskForVar, "x")
      body.add nnkForStmt.newTree(
        it, c[1], newStmtList(newCall(ident"add", acc, newCall(bindSym"toValue", it)))
      )
    else:
      body.add newCall(ident"add", acc, build(c, false))
  body.add newCall(mk, acc, newLit(marked))
  nnkBlockStmt.newTree(newEmptyNode(), body)

proc buildDict(n: NimNode, marked: bool): NimNode =
  var arr = nnkBracket.newTree()
  for e in n:
    if e.kind != nnkExprColonExpr:
      bad(e, "a dict is entries; write {k: v} or {:} for the empty one")
    arr.add nnkTupleConstr.newTree(build(e[0], false), build(e[1], false))
  newCall(bindSym"dict", nnkPrefix.newTree(ident"@", arr), newLit(marked))

proc build(n: NimNode, marked: bool): NimNode =
  case n.kind
  of nnkStmtList:
    if n.len != 1:
      bad(n, "one value here; a block of several is a program")
    build(n[0], marked)
  of nnkPar:
    if n.len != 1:
      bad(n, "() groups one value")
    build(n[0], marked)
  of nnkNilLit:
    newCall(bindSym"nilValue", newLit(marked))
  of nnkIntLit .. nnkUInt64Lit:
    newCall(bindSym"num", newLit($n.intVal), newLit(marked))
  of nnkFloatLit .. nnkFloat128Lit:
    bad(n, "there are no non-integer numbers; say (dec 15 -1) or (rat 42 54)")
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    newCall(bindSym"text", newLit(n.strVal), newLit(marked))
  of nnkIdent, nnkSym, nnkAccQuoted:
    var name = identOf(n)
    if name.endsWith("!") and name.len > 1:
      # `n!` -- the textual spelling of a marked atom, for holes and
      # for the rule words, so a shape reads the same in both syntaxes
      name.setLen(name.len - 1)
      return newCall(bindSym"sym", newLit(name), newLit(true))
    newCall(bindSym"sym", newLit(name), newLit(marked))
  of nnkCallStrLit:
    let lit = n[1].strVal
    case identOf(n[0])
    of "n": newCall(bindSym"num", newLit(lit), newLit(marked))
    of "s": newCall(bindSym"sym", newLit(lit), newLit(marked))
    of "t": newCall(bindSym"text", newLit(lit), newLit(marked))
    of "x": newCall(bindSym"bytes", newCall(bindSym"readHex", newLit(lit)), newLit(marked))
    of "b": newCall(bindSym"bytes", newCall(bindSym"toBytes", newLit(lit)), newLit(marked))
    else: bad(n, "unknown literal " & identOf(n[0]) & "\"...\"; n s t x b are the ones")
  of nnkPrefix:
    # Nim reads a run of operator characters as one token, so `!%x`
    # arrives as the single prefix `!%`. The mark peels off the front
    var op = identOf(n[0])
    var mk = marked
    if op.startsWith("!"):
      if mk:
        bad(n, "a value carries one mark")
      mk = true
      op = op[1 ..^ 1]
      if op.len == 0:
        return build(n[1], true)
    case op
    of "%":
      newCall(bindSym"blSplice", n[1], newLit(mk))
    of "%%":
      bad(n, "%% spreads inside a frame, and there is no frame here")
    else:
      bad(n, "no meaning for the prefix " & identOf(n[0]))
  of nnkBracket:
    buildFrame(n, 0, marked, "list")
  of nnkCurly:
    buildFrame(n, 0, marked, "set")
  of nnkTableConstr:
    buildDict(n, marked)
  of nnkCall, nnkCommand:
    # a record: the callee is the head. A head that is not a plain
    # name is written parenthesised -- (%h)(a b) -- and reads as one
    var head: NimNode
    case n[0].kind
    of nnkIdent, nnkSym, nnkAccQuoted:
      head = build(n[0], false)
    of nnkPar, nnkPrefix:
      head = build(n[0], false)
    else:
      bad(n[0], "a record's head is a name or a parenthesised value")
    let rest = buildFrame(n, 1, marked, "record")
    # splice the head in as element zero
    if rest.kind == nnkBlockStmt:
      let acc = rest[1][0][0][0]
      rest[1].insert 1, newCall(bindSym"add", acc, head)
      rest
    else:
      rest[1][1].insert 0, head
      rest
  else:
    bad(n, "no value spelling for " & $n.kind & ": " & n.repr)

macro bl*(x: untyped): Value =
  ##  Bassline Values written in nim
  ##
  ##  bl reads Nim's own surface syntax as a value literal.
  ##  It is similar, but not the same as the "bassline-text" syntax
  ##
  ##
  ##   nil                     nil
  ##
  ##   5 -3 n"123" 1_000       integer
  ##
  ##   "hi"                    text
  ##
  ##   foo `type` s"a b"       symbol
  ##
  ##   x"deadbeef"  b"raw"     bytestring
  ##
  ##   [a, b]                  list
  ##
  ##   {a, b} {}               set
  ##
  ##   {a: b} {:}              dict
  ##
  ##   head(a, b)              record
  ##
  ##   !anything               the same value but marked
  ##
  ## and two things the textual syntax cannot do at all
  ##
  ##   %expr                   splice a Nim expression in as a value
  ##   %%expr                  spread a Nim seq of them into this frame
  ##
  ## Splices go through `toValue[T](x: sink T): Value` which is
  ## enriched with lib/obm
  ##
  ## A value with no splices in it is an ordinary constant
  ## expression, so `const S = bl(...)` builds it once, at compile time.
  build(x, false)

proc blNode*(n: NimNode): NimNode =
  ## the same reading but kept as a nim node
  ## this is for other macros to use
  build(n, false)

macro program*(body: untyped): seq[Value] =
  ## program reads each statement as a value
  ## returning a seq
  var arr = nnkBracket.newTree()
  if body.kind == nnkStmtList:
    for r in body:
      arr.add blNode(r)
  else:
    arr.add blNode(body)
  nnkPrefix.newTree(ident"@", arr)