## bl jam mcp: jams as tools for an agent, over MCP on stdin and stdout
##
## The agent is one more speaker on each jam it is on, like a person at
## `bl jam` or a program on a pipe, and everything it says is there for
## anyone on that jam to read. Its tools are in values: `tell` hands a
## jam values exactly as the agent wrote them, (Q A) to put and (Q) to
## ask, and `heard` searches what a jam has told it, each told record
## shown as (heard Q R READINGS A), the answer verbatim and the session's
## own readings of it apart, before it, so a shape can stop short of it.
## `jams` says which jams it is on and, with scan, what answers on this
## machine's networks, as `bl jam scan` finds it; `join` and `leave` put
## it on one and take it off. Each jam is its own: its ranks, what it has
## told and what was said there are kept apart. With --push claude, what
## is said to it on any of them is pushed as a channel too; what was said
## to it before it came is pushed only if it wasn't here to hear it and
## hasn't answered it. A jam gone is dialled again, every two seconds.

import std/[algorithm, asyncdispatch, json, nativesockets, options, os, posix, random,
            sequtils, strutils, tables, times]
import harness, jam_client, jam_scan
import bl/[core, queries]
import bl/lib/jam

const Version = "0.3.0"

let
  HeardHead = sym"heard"
  DigestQ = sym"digest"
  SignerQ = sym"signer"
  VouchedQ = sym"vouched"
  ToYouQ = sym"to-you"
  JamName = sym"jam"

type
  PushMode = enum pushClaude, pushNone

  Asked = object
    ## what a call to heard keeps: a shape to fit, and from and how many
    shape: Option[Shape]
    since, first, last: int

  Line = ref object
    ## the session on one jam: the line to it, and what it has been told there
    m: Mcp
    place: Place
    c: Client
    asking: seq[Value]      ## every question it has asked, to ask again on a new line
    told: seq[Heard]        ## every answer the jam has told it, as it came
    ranks: Table[string, int]  ## a question and an answer's digest, to its rank
    newest: int             ## the newest rank told
    shown: int              ## the newest rank told when it last said anything to the agent
    mine: seq[Value]        ## digests of what it said, to know what answers it
    saidRe: BSet            ## digests of what it has answered
    here: Value             ## its here on this line, as the jam keeps it
    since: int              ## that here's rank, once told back; -1 until then
    backlog: seq[Heard]     ## said to it before then, pushed if it missed them
    tried: float            ## when it last dialled the jam

  Waiting = object
    ## a call to heard held until something new fits, its time is up, or
    ## the jam has gone
    id: JsonNode
    line: Line
    asked: Asked
    until: float

  Scanning = ref object
    ## a call to jams held until its scan is done
    id: JsonNode
    said: seq[string]       ## the jams it is on, said first
    found: seq[Value]       ## (found "HOST:PORT" TOLD), as bl jam scan writes it
    done: Future[int]

  Mcp = ref object
    speaker: Speaker
    lines: seq[Line]        ## the jams it is on, in the order it joined them
    rooms: seq[Value]       ## where it starts on a jam it joins
    pushMode: PushMode
    initialized: bool      ## whether the MCP client is ready for notifications
    pendingPushes: seq[(Line, Heard)]  ## eligible channel records waiting for initialization
    hearAll: bool           ## whether everything said where it asks is pushed
    waits: seq[Waiting]
    scans: seq[Scanning]
    found: seq[(string, Value)]  ## where the last scan found a jam, and which jam it said it is

# ================ what it reads in what it is told ================

proc firstName(id: Value): Value =
  ## an ID's first name that is a symbol or text, or the ID itself
  for n in identities(id):
    if n.kind in {bSym, bText}: return n
  id

proc isMe(m: Mcp, id: Value): bool = sharesIdentity(id, m.speaker.by)

proc ownRoom(m: Mcp): Value = initRec(@[ForQ, m.speaker.name])

proc key(q, digest: Value): string = $q & " " & $digest

proc which(l: Line): Option[Value] =
  ## which jam the line is to, once it has said
  if l.c == nil: none(Value) else: l.c.jam

proc called(l: Line): string = called(l.which)

proc jamName(l: Line): Value =
  ## the jam's first name, or its place until it has said which it is
  if l.which.isSome: firstName(l.which.get) else: toValue($l.place)

proc toYou(l: Line, h: Heard): Option[Value] =
  ## why an answer is said to the agent, if it is: in its own room, naming
  ## it, answering something it said, or for all. What it said itself is
  ## said to others
  let m = l.m
  let by = h.said.answer(ByQ)
  if by.isSome and m.isMe(by.get): return none(Value)
  if h.q == m.ownRoom: return some sym"room"
  if h.said.answers(ForQ).exists(n => m.isMe(n)): return some sym"named"
  if h.said.answers(ReQ).exists(d => d in l.mine): return some sym"answer"
  if h.said.isFor(m.speaker.by): return some sym"all"
  none(Value)

proc record(l: Line, h: Heard): Value =
  ## (heard Q R READINGS A): an answer as the jam told it, A as said, and
  ## what this session reads in it, the jam it came from among them
  var readings = @[(DigestQ, h.digestOf), (JamName, l.jamName)]
  let by = h.said.answer(ByQ)
  if by.isSome: readings.add (ByQ, firstName(by.get))
  if h.signer.isSome:
    readings.add (SignerQ, bytes(@(h.signer.get)))
    if h.vouched: readings.add (VouchedQ, firstName(by.get))
  var re: seq[Value]
  for d in h.said.answers(ReQ):
    let k = key(h.q, d)
    if k in l.ranks: re.add toValue(l.ranks[k])
  if re.len > 0: readings.add (ReQ, initList(re))
  let why = l.toYou(h)
  if why.isSome: readings.add (ToYouQ, why.get)
  initRec(@[HeardHead, h.q, toValue(h.rank), initDict(readings), h.said])

proc matching(l: Line, a: Asked): seq[Value] =
  ## the records that fit what heard was asked, oldest first
  var found: seq[(int, Value)]
  for h in l.told:
    if h.rank <= a.since: continue
    let r = l.record(h)
    if a.shape.isNone or a.shape.get.fillings(r).next.isSome: found.add (h.rank, r)
  found.sort((x, y) => cmp(x[0], y[0]))
  if a.first > 0: found[0 ..< min(found.len, a.first)].mapIt(it[1])
  else: found[max(0, found.len - a.last) .. ^1].mapIt(it[1])

# ================ what is pushed ================

proc notify(meth: string, params: JsonNode) =
  stdout.write $(%*{"jsonrpc": "2.0", "method": meth, "params": params}) & "\n"
  stdout.flushFile()

proc said(m: Mcp) =
  ## what has come so far on each jam is what had come when it last said
  ## anything to the agent: a wait is for what comes after that, so what
  ## comes while a call is on its way isn't passed over
  for l in m.lines: l.shown = l.newest

proc push(l: Line, h: Heard) =
  ## something said to the agent, pushed as a channel
  let m = l.m
  if m.pushMode == pushNone: return
  if not m.initialized:
    m.pendingPushes.add (l, h)
    return
  m.said()
  notify("notifications/claude/channel", %*{
    "content": $l.record(h),
    "meta": {"jam": $l.jamName, "room": $h.q, "rank": $h.rank,
             "by": $firstName(h.said.answer(ByQ).get)}})

proc firstHere(l: Line): int =
  ## where its name first said it was here, as far as it has been told
  for h in l.c.local.heardIn(HereQ):
    let by = h.said.answer(ByQ)
    if by.isSome and l.m.isMe(by.get): return h.rank
  l.since

proc catchUp(l: Line) =
  ## what was said to it before this line said it was here: pushed if it
  ## wasn't here then, by what the jam says of who came and went, and it
  ## hasn't answered it since. What is only for all, or only heard where
  ## it asks, is pushed only if said since it first came
  let first = l.firstHere
  for h in l.backlog:
    let why = l.toYou(h)
    if h.digestOf notin l.saidRe and not l.c.local.wasHere(l.m.speaker.by, h.rank) and
       ((why.isSome and why.get != sym"all") or h.rank > first):
      l.push(h)
  l.backlog.setLen 0

proc heard(l: Line, h: Heard) =
  let m = l.m
  l.told.add h
  l.ranks[key(h.q, h.digestOf)] = h.rank
  l.newest = max(l.newest, h.rank)
  if h.q == HereQ and l.since < 0 and h.answer == l.here:
    l.since = h.rank
    l.catchUp()
    return
  let by = h.said.answer(ByQ)
  if by.isNone: return
  if m.isMe(by.get):
    l.mine.add h.digestOf
    for d in h.said.answers(ReQ): l.saidRe.incl d
    return
  if h.said.answer(SaidQ).isNone: return
  if l.toYou(h).isSome or (m.hearAll and h.q in l.asking):
    if l.since < 0 or h.rank < l.since: l.backlog.add h
    else: l.push(h)

# ================ the lines to the jams ================

proc newLine(m: Mcp, place: Place, rooms: seq[Value]): Line =
  Line(m: m, place: place, asking: rooms, newest: -1, shown: -1, saidRe: newBSet(), since: -1)

proc connect(l: Line) =
  ## dials the jam, keeping what the line before was told
  l.tried = epochTime()
  l.c = dial(l.place, l.m.speaker, l.c)
  l.c.onHeard = (h: Heard) => l.heard(h)

proc greet(l: Line) =
  ## asks again everything it asked, and says it is here
  for q in l.asking: l.c.ask q
  l.since = -1
  l.here = l.c.hello()

proc reach(l: Line): Client =
  ## the line to the jam, dialled again if it has gone
  if l.c == nil or l.c.closed:
    l.connect()
    l.greet()
  l.c

proc keepUp(l: Line) =
  ## dials the jam again, every two seconds, once it has gone
  if (l.c == nil or l.c.closed) and epochTime() - l.tried >= 2:
    try: discard l.reach
    except CatchableError: discard

proc settle(ms = 300) =
  ## a moment for the jam to tell what it has
  let until = epochTime() + ms / 1000
  while epochTime() < until: turn(10)

proc ask(l: Line, q: Value) =
  if q notin l.asking:
    l.asking.add q
    l.reach.ask q
    settle()
    if l.since >= 0: l.catchUp()

proc up(l: Line): bool = l.c != nil and not l.c.closed

proc spelled(l: Line): string =
  ## the jam as the agent reads it in what the tools say: (NAME "HOST:PORT")
  let name = l.called
  (if name.len > 0: name else: "?") & " " & $toValue($l.place)

proc lineFor(m: Mcp, which: JsonNode): Line =
  ## the line to the jam `which` names, by its name or its place; the
  ## first it is on when nothing names one
  if which == nil or which.kind == JNull:
    if m.lines.len == 0:
      raise newException(ValueError, "on no jam now: join one (jams with scan finds them)")
    return m.lines[0]
  if which.kind != JString:
    raise newException(ValueError, "jam is a jam's name or its HOST:PORT")
  let s = which.getStr
  let named = m.lines.filterIt(it.called == s or $it.place == s)
  if named.len == 1: return named[0]
  if named.len > 1:
    raise newException(ValueError, "several jams go by " & s & ", at " &
      named.mapIt($it.place).join(" and ") & ": name one by its HOST:PORT")
  let place = try: some parsePlace(s) except ValueError: none(Place)
  if place.isSome:
    for l in m.lines:
      if $l.place == $place.get: return l
  raise newException(ValueError, "not on a jam called " & s & " (jams lists them)")

# ================ tools ================

let jamArg = %*{"type": "string", "description":
  "which jam: its name or HOST:PORT, as jams lists it (default the first this session is on)"}

proc tools(): JsonNode =
  %*[
    {"name": "tell", "description":
      "Tell the jam values, in bassline's text syntax, exactly as you write them: " &
      "(Q A) puts A as an answer to the question Q, and (Q) asks Q, so you hear every " &
      "answer to it, those it has and each as it comes. A room is a question and a " &
      "message an answer to it, an object: (general !{(by NAME) (said \"hi\")}), with " &
      "(re DIGEST) for what it answers and (for NAME) for whom it is for, all for " &
      "everyone. Putting an answer to Q asks Q too. If this session signs, each value " &
      "goes signed, unchanged inside the signature. Answers (put Q R) once the jam tells " &
      "it back at rank R, and (asked Q N) with how many answers it has told so far. " &
      "jam says which jam, when this session is on several.",
     "inputSchema": {"type": "object", "properties": {
       "value": {"type": "string", "description": "one or more values, (Q A) or (Q)"},
       "jam": jamArg},
       "required": ["value"]}},
    {"name": "heard", "description":
      "What the jam has told you, oldest first, one per line, each as " &
      "(heard Q R READINGS A): Q the question (a room), R the jam's order, READINGS what " &
      "this session reads in it, {digest: D (what (re D) names) jam: NAME by: NAME " &
      "signer: KEY vouched: NAME re: [R …] to-you: room|named|answer|all}, and A the answer " &
      "as it was said (checked and taken out of its signature, if signed). shape keeps what " &
      "fits, against the whole record. A record or list fits with members to spare, a dict or " &
      "set with entries to spare, and a hole fits only its own mark (a message is a marked " &
      "object): (shape (heard general) {}) is one room, (shape (heard q r {to-you: w}) " &
      "{q r w}) what is said to you, (shape (heard q r x !{(by b) (said (task t))}) " &
      "{q r x b t}) who asked for which task. since keeps what came after a rank; first keeps the oldest " &
      "matching records, or last the newest (default 30); first must be a positive integer, last a " &
      "non-negative integer, and they cannot be combined. wait holds up to that many seconds (at most 600) until something " &
      "comes that fits, after since or, without since, after what had come when you were last " &
      "told anything. jam says " &
      "which jam, when this session is on several: each jam's ranks are its own.",
     "inputSchema": {"type": "object", "properties": {
       "shape": {"type": "string", "description": "(shape EXAMPLE {HOLE …})"},
       "since": {"type": "integer", "description": "only what came after this rank"},
       "first": {"type": "integer", "minimum": 1,
                 "description": "at most this many, the oldest; cannot combine with last"},
       "last": {"type": "integer", "minimum": 0,
                "description": "at most this many, the newest (default 30); cannot combine with first"},
       "wait": {"type": "number", "description": "seconds to wait for something that fits"},
       "jam": jamArg}}},
    {"name": "jams", "description":
      "The jams this session is on, one per line: (on NAME \"HOST:PORT\") while its line is up, " &
      "(off NAME \"HOST:PORT\") while it is being dialled again. With scan, also every place on " &
      "this machine's networks that takes a connection on one of ports (default 8455 and 8456), " &
      "as bl jam scan writes it: (found \"HOST:PORT\" (jam R !{(identity NAME) …})) for a jam, " &
      "(found \"HOST:PORT\") for anything else. A network wider than /24 is looked at only in the /24 " &
      "around this machine's address on it. A scan takes a few seconds.",
     "inputSchema": {"type": "object", "properties": {
       "scan": {"type": "boolean", "description": "look on this machine's networks too"},
       "ports": {"type": "array", "items": {"type": "integer", "minimum": 1, "maximum": 65535},
                 "description": "the ports a scan tries (default 8455 and 8456)"},
       "net": {"type": "array", "items": {"type": "string"},
               "description": "networks to look on instead of this machine's own, " &
                              "each A.B.C.D/N or one address A.B.C.D"}}}},
    {"name": "join", "description":
      "Join a jam as well as those this session is on: at is its HOST:PORT, a name bl name " &
      "keeps for a place, or the name of a jam the last scan found. You ask rooms there " &
      "(default where this session began) and say you are here, under the same name and key. " &
      "Answers (joined NAME \"HOST:PORT\"). Joining a jam this session is on, at any place, " &
      "says so; joining the place of one that has become another jam starts over on the new one.",
     "inputSchema": {"type": "object", "properties": {
       "at": {"type": "string", "description": "HOST:PORT, a place's name, or a jam's name"},
       "rooms": {"type": "array", "items": {"type": "string"},
                 "description": "rooms to ask there, each a value (default where this session began)"}},
       "required": ["at"]}},
    {"name": "leave", "description":
      "Leave a jam: say you are gone there and close the line. What it told is no longer " &
      "searched. Answers (left NAME \"HOST:PORT\").",
     "inputSchema": {"type": "object", "properties": {"jam": jamArg}, "required": ["jam"]}}]

proc opens(l: Line, q, a: Value): bool =
  ## whether saying `a` in `q` opens a room nobody has listed: a message,
  ## in a question that isn't the jam's own or someone's own room
  if not (a.isObject and a.answer(ByQ).isSome): return false
  if q in [HereQ, GoneQ, RoomsQ, JamQ]: return false
  if q.isKind(bRec, unmarked) and q.len > 0 and q.head in [ForQ, StampsQ]: return false
  not l.c.local.heardIn(RoomsQ).exists(h => h.said == q)

proc tell(l: Line, text: string): string =
  let c = l.reach
  var said: seq[string]
  for v in readDocument(text):
    if v.isKind(bRec, unmarked) and v.len notin 1..2:
      raise newException(ValueError, "a jam takes (Q A) to put and (Q) to ask, not " & $v)
    let q = v.items[0]
    l.ask q
    if v.items.len == 1:
      said.add $initRec(@[sym"asked", q, toValue(c.local.heardIn(q).toSeq.len)])
      continue
    let a = v.items[1]
    if l.opens(q, a): discard c.put(RoomsQ, q)
    let kept = c.put(q, a)
    var told = none(int)
    let until = epochTime() + 2
    while told.isNone and epochTime() < until:
      let back = c.local.heardIn(q).filter(h => h.answer == kept).next
      if back.isSome: told = some back.get.rank
      else: turn(10)
    said.add $(if told.isSome: initRec(@[sym"put", q, toValue(told.get)])
               else: initRec(@[sym"put", q]))
    let here = c.local.who
    for name in a.answers(ForQ):
      let n = name
      if n == AllName: continue
      let came = c.local.heardIn(HereQ).exists(
        h => h.said.answer(ByQ).isSome and sharesIdentity(h.said.answer(ByQ).get, n))
      if not came:
        said.add $initRec(@[sym"note", toValue("no one going by " & $n &
                                               " has been on this jam, so no one may hear it")])
      elif not here.anyIt(sharesIdentity(it, n)):
        said.add $initRec(@[sym"note", toValue($n & " isn't on the jam now")])
  said.join("\n")

proc askedOf(l: Line, args: JsonNode): Asked =
  let first = args{"first"}
  let last = args{"last"}
  if first != nil and last != nil:
    raise newException(ValueError, "first and last cannot be combined")
  if first != nil:
    if first.kind != JInt or first.getInt <= 0:
      raise newException(ValueError, "first must be a positive integer")
    result.first = first.getInt
  if last != nil and (last.kind != JInt or last.getInt < 0):
    raise newException(ValueError, "last must be a non-negative integer")
  result.shape = if args{"shape"}.getStr.len > 0: some Shape.fromValue(readValue(args["shape"].getStr))
                 else: none(Shape)
  result.since = args{"since"}.getInt(if args{"wait"}.getFloat > 0: l.shown else: -1)
  result.last = args{"last"}.getInt(30)

proc lines(found: seq[Value]): string =
  if found.len == 0: "nothing heard fits" else: found.mapIt($it).join("\n")

proc onJams(m: Mcp): seq[string] =
  ## the jams it is on, as jams says them
  for l in m.lines:
    result.add "(" & (if l.up: "on " else: "off ") & l.spelled & ")"
    if l.c != nil and l.c.elsewhere.isSome:
      result.add $initRec(@[sym"note", toValue("the jam at " & $l.place & " is " &
        called(l.c.elsewhere) & " now: join " & $l.place & " to start over on it")])

proc portsOf(args: JsonNode): seq[Port] =
  let given = args{"ports"}
  if given == nil or given.kind == JNull: return @[Port(8455), Port(8456)]
  if given.kind != JArray or given.len == 0:
    raise newException(ValueError, "ports is a list of port numbers")
  for p in given:
    if p.kind != JInt or p.getInt notin 1..65535:
      raise newException(ValueError, "a port is a number from 1 to 65535, not " & $p)
    result.add Port(p.getInt)

proc scanning(m: Mcp, id: JsonNode, args: JsonNode) =
  ## starts a scan, answered when it is done, other calls meanwhile
  let ports = portsOf(args)
  let given = args{"net"}
  if given != nil and (given.kind != JArray or given.getElems.anyIt(it.kind != JString)):
    raise newException(ValueError, "net is a list of networks, each A.B.C.D/N or A.B.C.D")
  let nets = if given != nil and given.len > 0: given.getElems.mapIt(parseNet(it.getStr))
             else: networksHere()
  if nets.len == 0:
    raise newException(ValueError, "this machine is on no network but loopback")
  let s = Scanning(id: id, said: m.onJams)
  s.done = scan(nets, ports, m.speaker.ask(JamQ).ce.toString, 500,
                (v: Value) => s.found.add v)
  m.scans.add s

proc foundJams(m: Mcp, s: Scanning) =
  ## keeps where the scan found a jam, and which it said it is
  m.found.setLen 0
  for f in s.found:
    if f.items.len < 3: continue
    let h = heard(f.items[2])
    if h.isSome and h.get.q == JamQ: m.found.add (f.items[1].text, h.get.said)

proc placeOf(m: Mcp, at: string): Place =
  ## a place by its spelling, a name bl name keeps, or the name of a jam
  ## the last scan found
  let jams = m.found.filterIt(nameOf(it[1]) == at)
  if jams.len > 1 and jams.anyIt(it[1] != jams[0][1]):
    raise newException(ValueError, "the last scan found several jams called " & at & ", at " &
      jams.mapIt(it[0]).join(" and ") & ": join one by its HOST:PORT")
  let spelled = if jams.len > 0: jams[0][0] else: at
  result = try: parsePlace(spelled)
           except ValueError as e:
             raise newException(ValueError, e.msg & (if jams.len == 0 and m.found.len == 0:
               " (jams with scan finds the jams on this machine's networks)" else: ""))
  if result.kind != tcpPlace: raise newException(ValueError, "a jam is reached over tcp")

proc leave(m: Mcp, l: Line): string =
  if l.up: l.c.bye()
  m.lines.keepItIf(it != l)
  m.pendingPushes.keepItIf(it[0] != l)
  "(left " & l.spelled & ")"

proc join(m: Mcp, at: string, rooms: seq[Value]): string =
  var place = none(Place)
  let was = try: some m.lineFor(%at) except ValueError: none(Line)
  if was.isSome:
    let l = was.get
    if l.up: return "(on " & l.spelled & ")\n(note \"already on it\")"
    if l.c == nil or l.c.elsewhere.isNone:
      discard l.reach
      settle()
      return "(joined " & l.spelled & ")"
    discard m.leave(l)                     # another jam is there now: start over on it
    place = some l.place
  let l = m.newLine(if place.isSome: place.get else: m.placeOf(at),
                    if rooms.len > 0: rooms else: m.rooms)
  l.connect()
  let until = epochTime() + 2
  while l.which.isNone and not l.c.closed and epochTime() < until: turn(10)
  for other in m.lines:
    if other.which.isSome and other.which == l.which:
      l.c.hangUp()
      return "(on " & other.spelled & ")\n(note \"already on it, at " & $other.place & "\")"
  m.lines.add l
  l.greet()
  settle()
  "(joined " & l.spelled & ")"

# ================ MCP ================

proc instructions(m: Mcp): string =
  let places = m.lines.mapIt($it.place)
  """
You are """ & $m.speaker.name & """ on a jam at """ & places.join(", and on one at ") & """:
a place where people at terminals, other agents and programs talk in rooms. Everything
said there can be read by everyone on it, so say things for them, plainly.

You have two tools for talking, both in values. tell hands the jam values exactly as you write
them: (general !{(by """ & $m.speaker.by & """) (said "hi")}) says hi in general,
(general) asks for general. Write your by as that, so whoever reads it knows it is you""" &
  (if m.speaker.key.isSome: ", vouched by the key this session signs with" else: "") & """.
A message answers another with (re DIGEST), the digest heard shows for it, and is for
someone with (for NAME), all for everyone. heard searches what the jam has told you:
(heard ROOM RANK READINGS MESSAGE), the message verbatim and READINGS apart:
(shape (heard general) {}) is a room, (shape (heard q r {to-you: w}) {q r w}) what
is said to you.

What is said to you is in your own room """ & $m.ownRoom & """, names you or all, or answers
something you said. """ &
  (if m.pushMode == pushClaude:
    "It arrives as <channel source=\"jam\" jam=… room=… rank=… by=…> when channels are on; " &
    "otherwise call heard with a shape for to-you and wait. "
   else:
    "Standard MCP tools provide delivery when you ask. " &
    "Call heard with a shape for to-you and wait to hear new records. ") & """
Say a value (bassline text syntax, e.g. (task "review queries.nim")) when a program should read it.

You can be on several jams at once. jams lists those you are on and, with scan, finds the
jams on this machine's networks; join puts you on one, leave takes you off. tell and heard
take jam, a jam's name or HOST:PORT, to say which; without it they go to the first. Each
jam's ranks and rooms are its own, and READINGS say which jam a record came from."""

proc respond(m: Mcp, id: JsonNode, result: JsonNode) =
  m.said()
  stdout.write $(%*{"jsonrpc": "2.0", "id": id, "result": result}) & "\n"
  stdout.flushFile()

proc text(s: string): JsonNode = %*{"content": [{"type": "text", "text": s}]}

proc failed(name, msg: string): JsonNode =
  %*{"content": [{"type": "text", "text": name & ": " & msg}], "isError": true}

proc heardResult(l: Line, found: seq[Value]): JsonNode =
  ## the edge's own speaker, place and replay barrier, apart from the values heard
  result = text(lines(found))
  result["_meta"] = %*{"jam": {"name": $l.m.speaker.name, "place": $l.place,
                                "called": l.called, "joinedRank": l.since}}

proc answerWaits(m: Mcp) =
  ## answers each held call once something new fits, its time is up, or
  ## the jam has gone
  var i = 0
  while i < m.waits.len:
    let w = m.waits[i]
    let l = w.line
    let found = if l.newest > w.asked.since: l.matching(w.asked) else: @[]
    if found.len > 0 or epochTime() >= w.until or not l.up or l notin m.lines:
      m.waits.delete i
      m.respond(w.id, l.heardResult(found))
    else: inc i

proc answerScans(m: Mcp) =
  ## answers each held jams call once its scan is done
  var i = 0
  while i < m.scans.len:
    let s = m.scans[i]
    if not s.done.finished:
      inc i
      continue
    m.scans.delete i
    if s.done.failed:
      m.respond(s.id, failed("jams", s.done.readError.msg))
      continue
    m.foundJams(s)
    m.respond(s.id, text((s.said & s.found.mapIt($it)).join("\n")))

proc refuse(m: Mcp, id: JsonNode, code: int, msg: string) =
  m.said()
  stdout.write $(%*{"jsonrpc": "2.0", "id": id,
                    "error": {"code": code, "message": msg}}) & "\n"
  stdout.flushFile()

proc handle(m: Mcp, msg: JsonNode) =
  let meth = msg{"method"}.getStr
  let id = msg{"id"}
  if id == nil:
    if meth == "notifications/initialized" and not m.initialized:
      m.initialized = true
      for (l, h) in m.pendingPushes: l.push(h)
      m.pendingPushes.setLen 0
    return                                 # a notification: nothing to say
  case meth
  of "initialize":
    let capabilities = %*{"tools": {}}
    if m.pushMode == pushClaude:
      capabilities["experimental"] = %*{"claude/channel": {}}
    m.respond(id, %*{
      "protocolVersion": msg{"params", "protocolVersion"}.getStr("2025-06-18"),
      "capabilities": capabilities,
      "serverInfo": {"name": "jam", "version": Version},
      "instructions": m.instructions})
  of "ping": m.respond(id, newJObject())
  of "tools/list": m.respond(id, %*{"tools": tools()})
  of "tools/call":
    let name = msg{"params", "name"}.getStr
    let args = if msg{"params", "arguments"} == nil: newJObject()
               else: msg{"params", "arguments"}
    try:
      case name
      of "tell":
        m.respond(id, text(m.lineFor(args{"jam"}).tell(args{"value"}.getStr)))
      of "heard":
        let l = m.lineFor(args{"jam"})
        discard l.reach
        let asked = l.askedOf(args)
        let found = l.matching(asked)
        let wait = min(600.0, args{"wait"}.getFloat)
        if found.len > 0 or wait <= 0: m.respond(id, l.heardResult(found))
        else:                              # answered later, other calls meanwhile
          m.waits.add Waiting(id: id, line: l, asked: asked, until: epochTime() + wait)
      of "jams":
        if args{"scan"}.getBool: m.scanning(id, args)
        else:
          let on = m.onJams
          m.respond(id, text(if on.len > 0: on.join("\n") else: "on no jam"))
      of "join":
        if args{"at"}.getStr.len == 0: raise newException(ValueError, "at names a jam to join")
        let rooms = args{"rooms"}
        if rooms != nil and rooms.kind != JArray:
          raise newException(ValueError, "rooms is a list of rooms, each a value")
        m.respond(id, text(m.join(args["at"].getStr,
                                (if rooms == nil: @[] else: rooms.getElems.mapIt(readValue(it.getStr))))))
      of "leave":
        if args{"jam"} == nil: raise newException(ValueError, "jam names the jam to leave")
        m.respond(id, text(m.leave(m.lineFor(args["jam"]))))
      else: raise newException(ValueError, "no tool " & name)
    except CatchableError as e:
      m.respond(id, failed(name, e.msg))
  else: m.refuse(id, -32601, "no method " & meth)

proc run*(t: Tool, a: Args) =
  let pushMode = case a.get("push", "claude")
                 of "claude": pushClaude
                 of "none": pushNone
                 else: t.misuse "--push must be claude or none"
  randomize()
  var speaker = t.speakerFrom(a)
  if not a.has("as") and getEnv("JAM_NAME").len == 0:
    speaker.name = sym("claude-" & toHex(rand(0xFFFF), 4).toLowerAscii)
  let m = Mcp(speaker: speaker, pushMode: pushMode, hearAll: a.get("hear", "mine") == "all")
  let rooms = if a.positional.len > 0: a.positional else: @["general"]
  m.rooms = rooms.mapIt(readValue(it))
  let places =
    if a.every("at").len > 1:
      a.every("at").mapIt(try: parsePlace(it) except ValueError as e: t.misuse e.msg)
    else: @[t.placeFrom(a)]
  for place in places:
    if place.kind != tcpPlace: t.misuse "a jam is reached over tcp"
    let l = m.newLine(place, m.rooms)
    m.lines.add l
    try: discard l.reach
    except CatchableError as e:
      chatter "no jam at " & $place & " yet (" & e.msg & "); trying again every two seconds"
  var
    pending = ""
    buf = newString(65536)
  while true:
    turn(15)
    for l in m.lines: l.keepUp()
    m.answerWaits()
    m.answerScans()
    if not readable(0): continue
    let n = posix.read(0, addr buf[0], buf.len)
    if n <= 0: break                       # the agent has gone
    pending.add buf[0 ..< n]
    var nl = pending.find('\n')
    while nl >= 0:
      let line = pending[0 ..< nl].strip
      pending = pending[nl + 1 .. ^1]
      if line.len > 0:
        try: m.handle(parseJson(line))
        except JsonParsingError as e: m.refuse(newJNull(), -32700, e.msg)
      nl = pending.find('\n')
  for l in m.lines:
    if l.up: l.c.bye()
