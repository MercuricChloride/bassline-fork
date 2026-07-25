import std/os
import ../core
import ../lib/[grammar, read]
import ./[store, util]

export grammar

proc grammarValue*(spec: string, root: string): Value =
  ## A grammar argument is a value like any other: text or canonical
  ## bytes, inline or in a file, and a name resolves through the store.
  ## Which one it is, is a recognition rather than a spelling
  ## convention, so there is nothing to configure.
  if spec == "":
    quit "this command wants a grammar"
  if not fileExists(spec) and '/' in spec:
    quit "no such file: " & spec
  let text =
    if fileExists(spec):
      try:
        readFile(spec)
      except IOError as e:
        quit "can't read " & spec & ": " & e.msg
    else:
      spec
  result =
    try:
      decode(text)
    except DecodeError:
      try:
        readValue(text)
      except ReadError as e:
        quit "not a grammar: " & e.msg
  if result.isKind(bDict) and not result.marked:
    result = mark record(sym"grammar", result) # a bare rule table
  let name = fromValue(result, Digest)
  if name.isSome:
    let raw =
      try:
        openStore(root).load(name.get)
      except StoreError as e:
        quit e.msg
    if raw.isNone:
      quit "not in store: " & $result
    result =
      try:
        decode(raw.get)
      except DecodeError as e:
        quit "what the store holds under that name isn't a value: " & e.msg

proc grammarFrom*(spec: string, root: string): Grammar =
  try:
    load(grammarValue(spec, root))
  except GrammarError as e:
    quit "not a grammar: " & e.msg

proc startingRule*(g: Grammar, wanted: string): string =
  ## the rule a verb speaks for: the one asked for, or `start`
  if wanted != "":
    if wanted notin g.ruleNames:
      quit "this grammar names no rule '" & wanted & "'"
    return wanted
  if "start" notin g.ruleNames:
    quit "this grammar names no start rule; pass --rule"
  "start"
