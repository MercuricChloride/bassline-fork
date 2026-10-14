## bl name: this person's names for places, kept in ~/.bl/places.bl, so
## a place is spelled by name wherever one is taken

import std/[os, posix, sequtils, strutils]
import harness

proc keep(values: seq[Value]) =
  ## placesFile written whole: a fresh file beside it, then a rename
  let path = placesFile()
  try:
    createDir(path.parentDir)
    let fresh = path & ".new-" & $getpid()
    writeFile(fresh, values.mapIt(pretty(it) & "\n").join)
    moveFile(fresh, path)
  except OSError, IOError:
    fail "can't write " & path & ": " & getCurrentExceptionMsg()

proc run(t: Tool, a: Args) =
  let kept = keptNames()
  let forget = a.has("forget")
  if forget and a.positional.len != 1:
    t.misuse "--forget takes the one name to forget"
  if a.positional.len == 0:
    for v in kept:
      if naming(v).isSome: emit v
    return
  let name = a.positional[0]
  if not isName(name):
    t.misuse name & " isn't a name: a letter, then letters, digits, '.', '_' and '-'"
  let others = kept.filterIt(naming(it).isNone or naming(it).get[0] != name)
  if a.positional.len == 1 and not forget:
    if others.len == kept.len: fail "no place is named " & name
    for v in kept:
      if v notin others: emit v
    return
  if forget:
    if others.len == kept.len: fail "no place is named " & name
    keep others
    chatter "forgot " & name
    return
  var places: seq[string]
  for spelled in a.positional[1 .. ^1]:
    if isName(spelled):
      t.misuse "a name names places, not other names: " & spelled
    let p =
      try: parsePlace(spelled)
      except ValueError as e: t.misuse e.msg
    if p.kind != tcpPlace:
      t.misuse "a name names TCP places, not " & spelled
    places.add $p
  let named = initRec(@[sym"place", sym(name)] & places.mapIt(text(it)))
  # in the place of the naming it replaces, else after the rest
  var next: seq[Value]
  var put = false
  for v in kept:
    if v in others: next.add v
    elif not put: next.add named; put = true
  if not put: next.add named
  keep next
  chatter "named " & name & ": " & places.join(", ")

let tool* = Tool(
  name: "name",
  args: "[NAME [PLACE…]]",
  summary: "names for places, so a place is spelled by name",
  about: """
`bl name NAME PLACE…` names one or more TCP places NAME, replacing what
NAME named before. Wherever a place is taken, by send, reach and the
jam's clients with --at or JAM_AT, NAME is then the place it names: of
several, the first that takes a connection within half a second, so a
name can hold someone's address on this network and their .local name.

`bl name` alone writes every naming, (place NAME PLACE …) each, and
`bl name NAME` the one for NAME. --forget NAME takes a name away. The
names are kept in ~/.bl/places.bl, in the textual syntax, rewritten
whole when a name changes.

NAME is a letter, then letters, digits, '.', '_' and '-'. bl jam scan
finds places to name.""",
  opts: @[Opt(long: "forget", help: "take the name away")],
  run: run)
