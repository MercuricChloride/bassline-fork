include pkg/prelude
import std/[macros, strutils, sets]
import pkg/core
import ./runtime

func procPiece(name: string): string =
  ## Naiive normalization, this will likely change!
  ## "num-cmp" -> "NumCmp", "->dict" -> "Dict", "has?" -> "Has"
  var cap = true
  for ch in name:
    if ch.isAlphaNumeric:
      result.add (if cap: ch.toUpperAscii else: ch)
      cap = false
    else:
      cap = true

macro wordSet*(installer, body: untyped): untyped =
  ## a word set authoring macro
  ## 
  ##      wordSet installMine:
  ##        word "add":
  ##          numeric:
  ##            rt.push num(a.num + b.num)
  ##
  ## `wordSet` inspects the word forms itself and generates one named
  ## top-level proc per word.
  ## 
  ## Each proc binds the runtime as `rt` and the word's name as `wordName`.
  ## Plus this will export an installer to register the wordset with
  ## a runtime.
  installer.expectKind nnkIdent
  var prefix = $installer
  if prefix.startsWith("install") and prefix.len > "install".len:
    prefix = prefix["install".len .. ^1]
  prefix[0] = prefix[0].toLowerAscii

  result = newStmtList()
  var installs = newStmtList()
  var seen: HashSet[string]
  let rtId = ident"rt"
  let wnId = ident"wordName"

  for node in body:
    if node.kind in {nnkCall, nnkCommand} and node.len == 3 and
        node[0].kind == nnkIdent and node[0].strVal == "word":
      if node[1].kind notin nnkStrLit .. nnkTripleStrLit:
        error "word takes a string name", node[1]
      let name = node[1].strVal
      if name in seen:
        error "duplicate word: " & name, node[1]
      seen.incl name
      let piece = procPiece(name)
      if piece.len == 0:
        error "cannot derive a proc name from: " & name, node[1]
      let procId = ident(prefix & piece)
      let nameLit = newLit(name)
      let wbody = node[2]
      result.add quote do:
        proc `procId`(`rtId`: var Runtime) =
          const `wnId` {.used.} = `nameLit`
          `wbody`

      installs.add newCall(
        newDotExpr(rtId, ident"primitive"), nameLit, procId
      )
    else:
      result.add node

  result.add quote do:
    proc `installer`*(`rtId`: var Runtime) =
      `installs`

template refuse*(msg: string) {.dirty.} =
  ## a refusal under the current word's name
  fail wordName & ": " & msg

template lifted*(body: untyped) {.dirty.} =
  ## used for structural operations ie: core/ops as this word.
  ## converting a ValueError to a refusal under the words name.
  try:
    body
  except ValueError as e:
    refuse e.msg

template unary*(a, body: untyped) {.dirty.} =
  let a = pop rt
  body

template binary*(a, b, body: untyped) {.dirty.} =
  let
    b = pop rt
    a = pop rt
  body

func allKind*(kinds: set[BlKind], values: varargs[Value]): bool =
  for v in values:
    if not v.isKind(kinds):
      return false
  true

proc asIntIn*(v: Value, who: string): int =
  if not v.isKind(bNum):
    fail who & ": not a number"
  try:
    v.num.parseInt()
  except ValueError as e:
    fail who & ": " & e.msg

template asInt*(v: Value): int {.dirty.} =
  asIntIn(v, wordName)
