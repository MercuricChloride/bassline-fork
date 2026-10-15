## bl jam bridge: two jams, each told what is said on the other
##
## The bridge keeps a line to each jam and asks both the same questions:
## who is here and who has gone, which rooms there are, every room either
## lists, the own room of everyone either has heard from, the questions
## it is given, and every question a jam with a key has stamped. Whatever
## one jam tells it, it puts on the other, as it was put: an answer that
## came signed goes as it was signed, so either jam takes it as its
## speaker's and a reader on either can check it, and anything else as
## (Q A), signed by the bridge only if it signs. A jam keeps an answer
## once, and nothing a jam has told the bridge, or the bridge has put on
## it, is put on it again, so nothing goes round. Which jam each is, and
## its stamps, stay its own.
##
## The two lines go together. When either jam can't be reached the bridge
## hangs up on the other too, which says whoever the bridge brought there
## is gone, and dials both again. Whoever is still here hears they were
## called gone and says so again (jam_client), and the bridge brings that
## across too.

import std/[options, os, sequtils, strutils, times]
import harness, jam_client, jam_kept
import bl/[core, queries]
import bl/lib/jam

type
  End = ref object
    place: Place
    c: Client
    holds: BSet          ## every (Q A) it is known to hold: told, or put on it
    own: seq[Value]      ## what is asked of it alone: its stamps
    waiting: seq[Heard]  ## what the other told, for it, while it was down

  Bridge = ref object
    ends: array[2, End]
    speaker: Speaker
    signs: bool          ## whether what came unsigned goes signed
    asking: seq[Value]   ## what both are asked

proc isUp(e: End): bool = e.c != nil and not e.c.closed

proc isStamps(q: Value): bool =
  q.isKind(bRec, unmarked) and q.items.len == 2 and q.head == StampsQ

proc follow(b: Bridge, q: Value) =
  ## asks both `q`, from now on
  if q in b.asking or q == JamQ or q.isStamps: return
  b.asking.add q
  for e in b.ends:
    if e.isUp: e.c.ask q

proc pass(b: Bridge, i: int, h: Heard) =
  ## what end `i` told, put on the other end unless that holds it, or kept
  ## for it while it is down
  let (here, there) = (b.ends[i], b.ends[1 - i])
  let kept = initRec(@[h.q, h.answer])
  if kept in there.holds: return
  if not there.isUp:
    there.waiting.add h
    return
  let put = there.c.carry(h, b.signs)
  there.holds.incl kept
  if put != h.answer:
    let signed = initRec(@[h.q, put])
    there.holds.incl signed
    here.holds.incl signed

proc heard(b: Bridge, i: int, h: Heard) =
  ## what end `i` told: followed where it names questions, and passed on
  let here = b.ends[i]
  here.holds.incl initRec(@[h.q, h.answer])
  if h.q == JamQ:
    let name = identities(h.said).toSeq.filterIt(it.isKind({bSym, bText}))
    if name.len > 0:
      let stamps = initRec(@[StampsQ, name[0]])
      if stamps notin here.own:
        here.own.add stamps
        here.c.ask stamps
    return
  if h.q.isStamps:
    let s = stampOf(h)
    if s.isSome: b.follow(s.get.q)
    return
  if h.q == RoomsQ: b.follow(h.said)
  elif h.q in [HereQ, GoneQ]:
    let by = h.said.answer(ByQ)
    if by.isSome: b.follow(ownRoom(by.get))
  b.pass(i, h)

proc reach(b: Bridge, i: int) =
  ## a line to end `i`, keeping what the line before was told
  let e = b.ends[i]
  e.c = dial(e.place, b.speaker, e.c)
  e.c.onHeard = (h: Heard) => b.heard(i, h)
  for q in [JamQ, HereQ, GoneQ, RoomsQ].toSeq & b.asking & e.own:
    e.c.ask q

proc down(b: Bridge): bool =
  not b.ends.allIt(it.isUp)

proc hangUp(b: Bridge) =
  for e in b.ends:
    if e.c != nil: e.c.hangUp()

proc which(e: End): string =
  $e.place & (if called(e.c.jam).len > 0: " (" & called(e.c.jam) & ")" else: "")

var bridging: Bridge   # for ctrl-c, which can't close over anything

proc run*(t: Tool, a: Args) =
  if a.positional.len notin 1 .. 2: t.misuse "takes one place or two"
  var places: seq[Place]
  for spelled in a.positional:
    let p = try: parsePlace(spelled) except ValueError as e: t.misuse e.msg
    if p.kind != tcpPlace: t.misuse "a jam is reached over tcp"
    places.add p
  if places.len == 1: places.insert(t.placeFrom(a), 0)
  let b = Bridge(speaker: t.speakerFrom(a, signs = true), signs: a.has("sign"))
  for i in 0 .. 1: b.ends[i] = End(place: places[i], holds: newBSet())
  for q in a.every("ask"):
    try: b.follow(readValue(q))
    except ValueError as e: t.misuse "--ask " & q & ": " & e.msg
  bridging = b
  running(initRec(@[sym"bridge", initDict(@[
    (sym"ends", initList(places.mapIt(text($it)))),
    (sym"pid", toValue(getCurrentProcessId())), (sym"since", toValue(teatime.now()))])]))
  setControlCHook(proc() {.noconv.} =
    if bridging != nil: bridging.hangUp()
    quit 0)
  var lost = false
  while true:
    if b.down:
      b.hangUp()
      try:
        for i in 0 .. 1: b.reach(i)
        # which jam each is comes first; one jam can't be bridged to itself
        let until = epochTime() + 2
        while b.ends.anyIt(it.c.jam.isNone) and not b.down and epochTime() < until: turn(10)
        if b.ends[0].c.jam.isSome and b.ends[0].c.jam == b.ends[1].c.jam:
          b.hangUp()
          fail $places[0] & " and " & $places[1] & " are the same jam"
        for i in 0 .. 1:
          let waiting = b.ends[1 - i].waiting
          b.ends[1 - i].waiting.setLen 0
          for h in waiting: b.pass(i, h)
        chatter "bridging " & b.ends[0].which & " and " & b.ends[1].which
        lost = false
      except CatchableError as e:
        if not lost: chatter "can't bridge (" & e.msg & "); trying again"
        lost = true
        b.hangUp()
        sleep 2000
        continue
    turn(50)
    if b.down and not lost:
      let gone = b.ends.filterIt(it.c.closed).mapIt($it.place)
      chatter "lost " & gone.join(" and ") & "; dialling both again"
      lost = true
