## bl jam share: a search space shared on a jam, by a speaker who says
## what it finds there
##
## The space, written down as Search.fromValue reads one, is put under
## its digest, (DIGEST SPACE), and the digest under `knowledge`, so a
## program asks the jam (knowledge), picks a digest, and asks it for the
## space. It hears its own room and the rooms it is given (general by
## default). Whatever a message there says to it, in its own room or
## naming it, is asked of the space, and what it finds is said in the
## room the message was said in as (found QUERY {ANSWER …}), re the
## message and for whoever said it. Past `Most` answers, every answer is
## also put as ((found QUERY) ANSWER), and the message says
## (more (found QUERY)).
##
## It goes by the jam's order, not by any clock. On each line it asks
## everything first and puts its `here` last, and a jam tells a line in
## the order it took what the line said, so once the here is told back
## everything asked before it has been told. Then it knows which messages
## to it it has already said something re, and says what the rest find,
## those said while it was away among them; and a here ranked after its
## own is someone who has just come, told once, in their own room, what
## is shared and how to ask, as (sharing DIGEST TEXT). The first room
## hears the same, once ever. What a share says, `found` and `sharing`
## values, is passed over, so shares never set each other off.

import std/[options, os, sequtils, strutils]
import harness, jam_client
import bl/[core, queries]
import bl/lib/jam
import bl/lib/crypto/digest

let
  KnowledgeQ = sym"knowledge"   ## the digests of spaces shared whole
  HelpQ = sym"help"             ## how to ask a space
  AboutQ = sym"about"           ## what a space is
  FoundHead = sym"found"        ## what a query found: (found QUERY {ANSWER …})
  SharingHead = sym"sharing"    ## what a share shares: (sharing DIGEST TEXT)
  MoreQ = sym"more"             ## where the rest of what was found is put

const Most = 200  ## answers said in one message

type Share = ref object
  place: Place
  speaker: Speaker
  space: Value                  ## the space as written down
  digest: Value                 ## its digest, which the space is put under
  search: Search[Value, Value]  ## what it stands for
  rooms: seq[Value]             ## where it listens; the first hears it once
  c: Client
  here: Value                   ## the here it put on this line, as kept
  since: int                    ## that here's rank; -1 until told it
  waiting: seq[Heard]           ## messages to it told before that here
  saidRe: BSet                  ## digests of what it has said something re
  told: BSet                    ## own rooms of who has been told, this run

proc isMe(s: Share, id: Value): bool = sharesIdentity(id, s.speaker.by)

proc ownRoom(id: Value): Value =
  ## someone's own room: (for NAME), by the first name they go by
  for n in identities(id):
    if n.kind in {bSym, bText}: return initRec(@[ForQ, n])
  initRec(@[ForQ, id])

proc toIt(s: Share, h: Heard): bool =
  ## whether a message is said to it: in its own room, or naming it
  h.q == ownRoom(s.speaker.by) or
    h.said.answers(ForQ).exists(n => s.isMe(n))

proc fromAShare(said: Value): bool =
  ## whether something said is what a share says
  said.isKind(bRec, unmarked) and said.items.len > 1 and said.head in [FoundHead, SharingHead]

proc sharing(s: Share): Value =
  ## what it shares and how to ask, for whoever comes
  let me = $s.speaker.name
  var text = me & " here, sharing a search space"
  let about = s.space.answer(AboutQ)
  if about.isSome and about.get.kind == bText: text.add ": " & about.get.text
  text.add ". Say a question to me, in my room " & $ownRoom(s.speaker.by) &
    " or naming me in " & s.rooms.mapIt($it).join(" or ") &
    ", and I say what it finds as (found QUESTION {ANSWER …}) in the room " &
    "you said it in."
  for h in s.search.ask(HelpQ):
    if h.kind == bText: text.add " " & h.text
  text.add " A program asks the jam (knowledge) for the space's digest, " &
    "asks the jam that digest for the space, and reads it with " &
    "Search[Value, Value].fromValue."
  initRec(@[SharingHead, s.digest, toValue(text)])

proc saidIn(s: Share, room: Value): bool =
  ## whether it has said anything in `room`, as far as the jam has told it
  s.c.local.heardIn(room).exists(
    h => h.said.answer(ByQ).isSome and s.isMe(h.said.answer(ByQ).get))

proc find(s: Share, h: Heard) =
  ## asks the space what a message says, and says what it found
  let query = h.said.answer(SaidQ).get
  var found: seq[Value]
  var more = false
  for a in s.search.ask(query):
    if found.len == Most:
      more = true
      break
    found.add a
  var said = @[FoundHead, query, initSet(found)]
  if more:
    let q = initRec(@[FoundHead, query])
    for a in s.search.ask(query): discard s.c.put(q, a)
    said.add initRec(@[MoreQ, q])
  discard s.c.put(h.q, s.speaker.message(initRec(said), [h.digestOf],
                                         [h.said.answer(ByQ).get]))

proc caughtUp(s: Share) =
  ## everything asked before the here has been told: what is waiting and
  ## not yet said something re is found, and the first room hears what is
  ## shared if it never has
  for h in s.waiting:
    if h.digestOf notin s.saidRe: s.find(h)
  s.waiting.setLen 0
  if s.rooms.len > 0 and not s.saidIn(s.rooms[0]):
    discard s.c.put(s.rooms[0], s.speaker.message(s.sharing))

proc heard(s: Share, h: Heard) =
  if h.q == HereQ:
    if s.since < 0:
      if h.answer == s.here:
        s.since = h.rank
        s.caughtUp()
    elif h.rank > s.since:
      let by = h.said.answer(ByQ)
      if by.isSome and not s.isMe(by.get):
        let room = ownRoom(by.get)
        if room notin s.told:
          s.told.incl room
          discard s.c.put(room, s.speaker.message(s.sharing))
    return
  let by = h.said.answer(ByQ)
  let said = h.said.answer(SaidQ)
  if by.isNone or said.isNone: return
  if s.isMe(by.get):
    for d in h.said.answers(ReQ): s.saidRe.incl d
  elif not fromAShare(said.get) and s.toIt(h):
    if s.since < 0: s.waiting.add h
    else: s.find(h)

proc reach(s: Share): Client =
  ## the line to the jam, dialled again if it has gone
  if s.c == nil or s.c.closed:
    s.c = dial(s.place, s.speaker)
    s.since = -1
    s.waiting.setLen 0
    s.c.onHeard = (h: Heard) => s.heard(h)
    for q in @[HereQ, ownRoom(s.speaker.by)] & s.rooms:
      s.c.ask q
    for r in s.rooms:
      if not r.isKind(bRec) or r.items.len != 2 or r.head != ForQ:
        discard s.c.put(RoomsQ, r)
    discard s.c.put(KnowledgeQ, s.digest)
    discard s.c.put(s.digest, s.space)
    s.here = s.c.put(HereQ, s.speaker.here)
  s.c

var running: Client   # for ctrl-c, which can't close over anything

proc run*(t: Tool, a: Args) =
  if a.positional.len == 0: t.misuse "takes the space to share"
  let space =
    try: valueArg(a.positional[0])
    except ValueError as e: t.misuse e.msg
  let search =
    try: Search[Value, Value].fromValue(space)
    except ValueError as e: fail a.positional[0] & " isn't a search space: " & e.msg
  var speaker = t.speakerFrom(a)
  if not a.has("as") and getEnv("JAM_NAME").len == 0: speaker.name = sym"kb"
  let rooms = if a.positional.len > 1: a.positional[1 .. ^1] else: @["general"]
  let s = Share(place: t.placeFrom(a), speaker: speaker, space: space,
                digest: digest(space, Blake2bAlgo).toValue, search: search,
                rooms: rooms.mapIt(readValue(it)), since: -1, saidRe: newBSet(),
                told: newBSet())
  setControlCHook(proc() {.noconv.} =
    if running != nil and not running.closed: running.bye()
    quit 0)
  var down = false
  while true:
    try:
      running = s.reach
      if down: chatter "on the jam at " & $s.place & " again"
      down = false
    except CatchableError as e:
      if not down: chatter "no jam at " & $s.place & " (" & e.msg & "); trying again"
      down = true
      sleep 2000
      continue
    turn(50)
