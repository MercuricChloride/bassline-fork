## bl jam keep: a keeper on a jam, holding files by their digests and
## putting what someone wants
##
## A keeper holds a keep (bl/lib/fs), values filed under their digests,
## and hears its rooms (fs by default) and its own. A message saying
## (want D) for each digest someone lacks is taken up by a keeper that
## holds some of them and hasn't been told the jam answers them: it asks
## the jam each, and says (has D) for each, re the want. A jam tells a
## line in the order it took what the line said, so once the has is told
## back the jam has told everything it had for those digests. Then the
## keeper puts (D V) for each D the jam hasn't answered and no earlier
## (has D) re the same want names, so of several keepers the first to say
## has, in the jam's order, puts it, and the jam keeps it once.
##
## A message saying (keep D) has the keeper fetch D and everything under
## it, a manifest's chunks and a tree's entries: it asks the jam for what
## its keep lacks, says (want D) re the keep for each, stores every
## answer that checks against its digest, and says (kept D) re the keep
## once it holds all of it. A want or keep that says whom it is for, not
## naming the keeper or all, is left to them.
##
## A jam may pass content through rather than keep it (bl jam serve
## --pass): the keeper stores what is passed to it as it stores what is
## told, and counts only what the jam keeps as the jam answering a
## digest, so it answers a later want for what was only passed.
##
## It goes by the jam's order, as jam share does: on each line it asks
## everything first and puts its here last, and once the here is told
## back takes up what was said to it while it was away, unless it has
## said something re it already, or, for a want, someone has said has re
## it. The first room hears, once ever, that it keeps here. It tells what
## it said apart from what others said by the messages themselves, not
## by who signed them, so a want said with its own key, by bl fs on the
## same machine, is taken up like any other.

import std/[options, os, sequtils, sets, tables]
import harness, jam_client
import bl/[core, queries]
import bl/lib/[jam, fs]

let
  WantQ = sym"want"   ## a digest someone lacks: (want D)
  HasQ = sym"has"     ## a digest a keeper holds and may put: (has D)
  KeepQ = sym"keep"   ## a digest to fetch and hold, with all under it: (keep D)
  KeptQ = sym"kept"   ## a digest held with all under it: (kept D)

type
  Offer = object
    ## a has it said and hasn't yet heard told back
    room: Value
    want: Value      ## the want's digest
    ds: seq[Value]   ## the digests it offered

  Keeping = ref object
    ## a keep it took up
    room: Value
    re: Value        ## the keep's digest
    by: Value        ## who asked
    roots: seq[Value]
    wanted: HashSet[Value]  ## what it has said it wants for it

  Keeper = ref object
    place: Place
    speaker: Speaker
    keep: Keep
    search: Search[Value, Value]  ## the keep, a digest to what it holds
    rooms: seq[Value]             ## where it listens; the first hears it once
    c: Client
    here: Value                   ## the here it put on this line, as kept
    since: int                    ## that here's rank; -1 until told it
    waiting: seq[Heard]           ## wants and keeps told before that here
    saidRe: HashSet[Value]        ## digests of what it has said something re
    asked: HashSet[Value]         ## digests it has asked the jam
    onJam: HashSet[Value]         ## digests the jam keeps an answer for that checks
    offers: Table[Value, Offer]   ## its has messages, by the answer as kept
    mine: HashSet[Value]          ## what it has said this run, as kept
    keeping: seq[Keeping]
    stirred: bool                 ## whether a keep may have moved on

proc isMe(k: Keeper, id: Value): bool = sharesIdentity(id, k.speaker.by)

proc byOf(h: Heard): Option[Value] = h.said.answer(byQ)

proc listens(k: Keeper, room: Value): bool =
  room in k.rooms or room == ownRoom(k.speaker.by)

proc toIt(k: Keeper, h: Heard): bool =
  ## whether a want or keep is its to take up: in its own room, or saying
  ## for no one, or naming it or all
  h.q == ownRoom(k.speaker.by) or h.said.answers(forQ).next.isNone or
    h.said.isFor(k.speaker.by)

proc ask(k: Keeper, d: Value) =
  k.asked.incl d
  k.c.ask d

proc say(k: Keeper, room, re: Value, to: openArray[Value], records: seq[Value],
         text: string): Value =
  ## says `records` in `room`, re the message whose digest is `re` and
  ## for `to`, answering the message as the jam will keep it
  var members = @[initRec(@[byQ, k.speaker.by]), initRec(@[reQ, re]),
                  initRec(@[saidQ, text(text)]), initRec(@[atQ, toValue(now())])]
  for n in to: members.add initRec(@[forQ, n])
  result = k.c.put(room, obj(members & records))
  k.mine.incl result

proc offer(k: Keeper, h: Heard) =
  ## a want: asks the jam each digest it holds that the jam isn't known to
  ## answer, and says it has them
  let ds = h.said.answers(WantQ).toSeq.filterIt(it notin k.onJam and k.keep.holds(it))
  if ds.len == 0: return
  for d in ds: k.ask d
  let kept = k.say(h.q, h.digestOf, [h.byOf.get], ds.mapIt(initRec(@[HasQ, it])),
                   $k.speaker.name & " has " & $ds.len & " of what was wanted")
  k.offers[kept] = Offer(room: h.q, want: h.digestOf, ds: ds)

proc settle(k: Keeper, h: Heard) =
  ## its has is told back: the jam has told all it had for those digests,
  ## and every earlier has re the same want. It puts what nobody answered
  ## and no one offered first
  let o = k.offers[h.answer]
  k.offers.del h.answer
  let first = k.c.local.heardIn(o.room).filter((e: Heard) =>
    e.rank < h.rank and e.said.answers(reQ).exists(d => d == o.want)).toSeq
  let offered = first.mapIt(it.said.answers(HasQ).toSeq).concat
  for d in o.ds:
    if d in k.onJam or d in offered: continue
    let v =
      try: k.keep.fetch(d)
      except CatchableError as e:
        chatter "can't read " & $d & " from the keep: " & e.msg
        none(Value)
    if v.isSome: discard k.c.put(d, v.get)

proc takeUp(k: Keeper, h: Heard) =
  if h.said.answers(WantQ).next.isSome: k.offer(h)
  let roots = h.said.answers(KeepQ).toSeq
  if roots.len > 0:
    k.keeping.add Keeping(room: h.q, re: h.digestOf, by: h.byOf.get, roots: roots)
    k.stirred = true

proc moveOn(k: Keeper) =
  ## each keep says it wants what its keeper newly finds it lacks, or that
  ## it is kept once nothing is lacking
  k.stirred = false
  var going: seq[Keeping]
  for p in k.keeping:
    var lacking: seq[Value]
    for r in p.roots:
      for d in k.search.missing(r):
        if d notin lacking: lacking.add d
    if lacking.len == 0:
      discard k.say(p.room, p.re, [p.by], p.roots.mapIt(initRec(@[KeptQ, it])),
                    $k.speaker.name & " keeps it all")
      continue
    going.add p
    let fresh = lacking.filterIt(it notin p.wanted)
    if fresh.len > 0:
      for d in fresh:
        k.ask d
        p.wanted.incl d
      # for no one, so every keeper hears it
      discard k.say(p.room, p.re, [], fresh.mapIt(initRec(@[WantQ, it])),
                    $k.speaker.name & " wants " & $fresh.len & " more to keep it")
  k.keeping = going

proc saidIn(k: Keeper, room: Value): bool =
  ## whether it has said anything in `room`, as far as the jam has told it
  k.c.local.heardIn(room).exists(h => h.byOf.isSome and k.isMe(h.byOf.get))

proc offeredRe(k: Keeper, h: Heard): bool =
  ## whether someone has said has re a want
  let d = h.digestOf
  k.c.local.heardIn(h.q).exists((e: Heard) =>
    e.said.answers(HasQ).next.isSome and e.said.answers(reQ).exists(x => x == d))

proc caughtUp(k: Keeper) =
  ## everything asked before the here has been told: what was said to it
  ## while it was away is taken up, and the first room hears it keeps
  ## here if it never has
  for h in k.waiting:
    if h.digestOf in k.saidRe: continue
    if h.said.answers(KeepQ).next.isNone and k.offeredRe(h): continue
    k.takeUp(h)
  k.waiting.setLen 0
  if k.rooms.len > 0 and not k.saidIn(k.rooms[0]):
    let me = $k.speaker.name
    k.mine.incl k.c.put(k.rooms[0], obj(initRec(@[byQ, k.speaker.by]), initRec(@[atQ, toValue(now())]),
      initRec(@[saidQ, text(me & " keeps files here. Say (want D) for each digest you lack " &
        "and it puts what it holds; say (keep D) and it fetches D and all under it, " &
        "and says (kept D) once it holds them.")])))

proc content(k: Keeper, d, v: Value) =
  ## an answer to a digest it asked: kept when it checks
  if not k.keep.holds(d):
    try:
      discard k.keep.store(v)
      k.stirred = true
    except CatchableError as e:
      chatter "can't keep " & $d & ": " & e.msg

proc passed(k: Keeper, p: Passed) =
  if p.q in k.asked and verifies(p.q, p.said): k.content(p.q, p.said)

proc heard(k: Keeper, h: Heard) =
  if h.q == hereQ:
    if k.since < 0 and h.answer == k.here:
      k.since = h.rank
      k.caughtUp()
    return
  if h.q in k.asked:
    if verifies(h.q, h.said):
      k.onJam.incl h.q
      k.content(h.q, h.said)
    return
  if not k.listens(h.q) or h.byOf.isNone: return
  if h.answer in k.offers: k.settle(h)
  if k.isMe(h.byOf.get):
    for d in h.said.answers(reQ): k.saidRe.incl d
  if h.answer in k.mine: return
  if h.said.answers(WantQ).next.isNone and h.said.answers(KeepQ).next.isNone: return
  if not k.toIt(h): return
  if k.since < 0: k.waiting.add h
  else: k.takeUp(h)

proc reach(k: Keeper): Client =
  ## the line to the jam, dialled again if it has gone
  if k.c == nil or k.c.closed:
    k.c = dial(k.place, k.speaker)
    k.since = -1
    k.waiting.setLen 0
    k.c.onHeard = (h: Heard) => k.heard(h)
    k.c.onPassed = (p: Passed) => k.passed(p)
    for q in @[hereQ, ownRoom(k.speaker.by)] & k.rooms:
      k.c.ask q
    for r in k.rooms:
      if not r.isKind(bRec) or r.items.len != 2 or r.head != forQ:
        discard k.c.put(roomsQ, r)
    for d in k.asked: k.c.ask d
    k.here = k.c.put(hereQ, k.speaker.here)
  k.c

var running: Client   # for ctrl-c, which can't close over anything

proc run*(t: Tool, a: Args) =
  var speaker = t.speakerFrom(a, signs = true)
  if not a.has("as") and getEnv("JAM_NAME").len == 0: speaker.name = sym"keeper"
  let path = a.get("keep", getHomeDir() / ".bl" / "fs" / "keep.blb")
  if path.parentDir.len > 0: createDir(path.parentDir)
  let keep =
    try: openKeep(path)
    except CatchableError as e: fail "can't keep in " & path & ": " & e.msg
  let rooms = if a.positional.len > 0: a.positional else: @["fs"]
  let k = Keeper(place: t.placeFrom(a), speaker: speaker, keep: keep,
                 search: keepSearch(keep), rooms: rooms.mapIt(readValue(it)), since: -1)
  setControlCHook(proc() {.noconv.} =
    if running != nil and not running.closed: running.bye()
    quit 0)
  chatter "keeping in " & path & ", " & $keep.held.len & " values held"
  var down = false
  while true:
    try:
      running = k.reach
      if down: chatter "on the jam at " & $k.place & " again"
      down = false
    except CatchableError as e:
      if not down: chatter "no jam at " & $k.place & " (" & e.msg & "); trying again"
      down = true
      sleep 2000
      continue
    turn(50)
    if k.stirred and k.since >= 0: k.moveOn()
