## bl name: this person's names for places, kept in the config as
## ((place NAME) PLACE) answers, so a place is spelled by name wherever
## one is taken

import std/[sequtils, strutils]
import harness

proc isNaming(v: Value): bool =
  let qa = answerOf(v)
  qa.isSome and qa.get[0].isKind(bRec, unmarked) and qa.get[0].items.len == 2 and
    qa.get[0].head == sym"place"

proc run(t: Tool, a: Args) =
  let forgetting = a.has("forget")
  if forgetting and a.positional.len != 1:
    t.misuse "--forget takes the one name to forget"
  if a.positional.len == 0:
    for v in configValues():
      if isNaming(v): emit v
    return
  let name = a.positional[0]
  if not isName(name):
    t.misuse name & " isn't a name: a letter, then letters, digits, '.', '_' and '-'"
  let q = placeQ(name)
  if forgetting:
    if not forget(q): fail "no place is named " & name
    chatter "forgot " & name
    return
  if a.positional.len == 1:
    let places = configured(q)
    if places.len == 0: fail "no place is named " & name
    for p in places: emit initRec(@[q, p])
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
  configure(q, places.mapIt(text(it)))
  chatter "named " & name & ": " & places.join(", ")

let tool* = Tool(
  name: "name",
  args: "[NAME [PLACE…]]",
  summary: "names for places, so a place is spelled by name",
  about: """
`bl name NAME PLACE…` names one or more TCP places NAME, in place of
what NAME named before. Wherever a place is taken, by send, reach and
the jam's clients with --at, JAM_AT or the config's at, NAME is then the
place it names: of several, the first that takes a connection within
half a second, so a name can hold someone's address on this network and
their .local name.

`bl name` alone writes every naming, ((place NAME) PLACE) for each
place, and `bl name NAME` those for NAME. --forget NAME takes a name
away. The names are answers in the config, ~/.bl/config.bl, so `bl
config '(place NAME)'` reads them too.

NAME is a letter, then letters, digits, '.', '_' and '-'. bl scan finds
places to name.""",
  opts: @[Opt(long: "forget", help: "take the name away")],
  run: run)
