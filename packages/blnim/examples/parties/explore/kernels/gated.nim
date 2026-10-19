## A party that admits only the topics it was given, and the names of
## those here to hear and say into. Anything else is said back as
## (invalid X). It goes by (gated TOPICS ORDER), so whoever arrives can
## read what it may do here.
import std/[os, sysrand]
import bl/core
import ./kernel

type Gated* = ref object of Party
  topics: Value

method admits(p: Gated, s: Seat, verb, t: Value): bool =
  if t in p.topics.els: return true
  if verb == bl"own": return false
  for o in p.seats:
    if o.name == t: return true

proc gated*(topics: Value): Gated =
  let order = bytes(urandom 16)
  Gated(name: bl"(gated $topics $order)", topics: topics)

when isMainModule:
  if paramCount() != 1: quit "gated TOPICS, a set in the textual syntax"
  gated(readValue(paramStr(1))).serve.announce
  runForever()
