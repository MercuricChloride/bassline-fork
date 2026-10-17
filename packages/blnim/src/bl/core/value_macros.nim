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

macro blet*(src: string, exported = true) =
  ##[
    Parses bassline text into a series of let bindings for values

    When given a set of symbols, it will generate a
    let statement of the symbol.
    

    ie: when given {foo bar baz} it generates:
      let foo = sym"foo"
      let bar = sym"bar"
      let baz = sym"baz"

    When given a dict with symbol keys it binds the symbol to their
    associated value.

    ie: when given {foo: [1 2 3]} it generates:
      let foo = initList([1,2,3])
  ]##
  src.expectKind({nnkStrLit, nnkTripleStrLit, nnkRStrLit})
  let 
    declarations = newTree(nnkStmtList)
    isExported = exported.boolVal
  for (name, val) in letTerms(src.strVal):
    let 
      nameIdent = ident(name)
      valLit = emitFmtAST(val)
    if isExported:
      declarations.add(
        quote do:
          let `nameIdent`* = `valLit`)
    else:
      declarations.add(
        quote do:
          let `nameIdent` = `valLit`)
  result = declarations

proc emitFmtAST(val: Value): NimNode =
  ## the code that builds `val`, as it would be written by hand: an atom
  ## as a literal, a frame by its builder (newLit can't write one, it
  ## sees only the Frame a frame is held as), and $NAME as the Nim value
  ## NAME, spelled as blet spells it
  let mark = val.mark
  case val.kind
  of bSym:
    if not val.text.startsWith("$"):
      return newLit(val)
    if val.text.startsWith("$$"):
      return newLit(sym(val.text[1 .. ^1], mark))
    let spliced = ident(nimSpelling(val.text[1 .. ^1], false))
    return
      if mark: quote do: withMark(toValue(`spliced`))
      else: quote do: toValue(`spliced`)
  of bList, bRec:
    let items = newTree(nnkBracket)
    for child in val.children:
      items.add(emitFmtAST(child))
    return
      if val.kind == bList: quote do: initList(@`items`, `mark`)
      else: quote do: initRec(@`items`, `mark`)
  of bSet:
    let setArgs = newTree(nnkBracket)
    for child in val.children:
      setArgs.add(emitFmtAST(child))
    return quote do:
      initSet(`setArgs`, `mark`)
  of bDict:
    let dictArgs = newTree(nnkBracket)
    for k, v in val.dict:
      dictArgs.add(newTree(nnkTupleConstr, emitFmtAST(k), emitFmtAST(v)))
    return quote do:
      initDict(`dictArgs`, `mark`)
  else:
    return newLit(val)

macro blfmt*(src: string): untyped =
  ##[
    Reads bassline text and generates the code that builds
    that value at runtime.

    Symbols that begin with $ are treated as holes, where $name
    is the name of a nim binding of a Value. The name is spelled as blet 
    spells it, so $foo-bar is fooBar. A marked hole, $name!, marks what 
    goes in. $$name is the symbol $name itself and not a hole.

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

template bl*(src: string): untyped =
  blfmt(src)