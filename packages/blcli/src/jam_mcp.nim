## bl jam mcp: a jam as tools for an agent, over MCP on stdin and stdout
##
## The agent is one more speaker on the jam, like a person at `bl jam`
## or a program on a pipe, and everything it says is there for anyone to
## read. It has two tools, both in values: `tell` hands the jam values
## exactly as the agent wrote them, (Q A) to put and (Q) to ask, and
## `heard` searches what the jam has told it, each told record shown as
## (heard Q R READINGS A), the answer verbatim and the session's own
## readings of it apart, before it, so a shape can stop short of it. With
## --push claude, what is said to it is pushed as a channel too;
## what was said to it before it came is pushed only if it wasn't here to
## hear it and hasn't answered it. A jam gone is dialled again, every two
## seconds.

import std/[algorithm, json, options, os, posix, random, sequtils, strutils, tables, times]
import harness, jam_client
import bl/[core, queries]
import bl/lib/jam

const Version = "0.2.0"

let
  HeardHead = sym"heard"
  DigestQ = sym"digest"
  SignerQ = sym"signer"
  VouchedQ = sym"vouched"
  ToYouQ = sym"to-you"

type
  PushMode = enum pushClaude, pushNone

  Asked = object
    ## what a call to heard keeps: a shape to fit, and from and how many
    shape: Option[Shape]
    since, first, last: int

  Waiting = object
    ## a call to heard held until something new fits, or its time is up
    id: JsonNode
    asked: Asked
    until: float

  Mcp = ref object
    place: Place
    speaker: Speaker
    c: Client
    asking: seq[Value]      ## every question it has asked, to ask again on a new line
    pushMode: PushMode
    initialized: bool      ## whether the MCP client is ready for notifications
    pendingPushes: seq[Heard]  ## eligible channel records waiting for initialization
    hearAll: bool           ## whether everything said where it asks is pushed
    told: seq[Heard]        ## every answer the jam has told it, as it came
    ranks: Table[string, int]  ## a question and an answer's digest, to its rank
    newest: int             ## the newest rank told
    mine: seq[Value]        ## digests of what it said, to know what answers it
    saidRe: BSet            ## digests of what it has answered
    here: Value             ## its here on this line, as the jam keeps it
    since: int              ## that here's rank, once told back; -1 until then
    backlog: seq[Heard]     ## said to it before then, pushed if it missed them
    waits: seq[Waiting]
    tried: float            ## when it last dialled the jam

# ================ what it reads in what it is told ================

proc firstName(id: Value): Value =
  ## an ID's first name that is a symbol or text, or the ID itself
  for n in identities(id):
    if n.kind in {bSym, bText}: return n
  id

proc isMe(m: Mcp, id: Value): bool = sharesIdentity(id, m.speaker.by)

proc ownRoom(m: Mcp): Value = initRec(@[ForQ, m.speaker.name])

proc key(q, digest: Value): string = $q & " " & $digest

proc toYou(m: Mcp, h: Heard): Option[Value] =
  ## why an answer is said to the agent, if it is: in its own room, naming
  ## it, answering something it said, or for all. What it said itself is
  ## said to others
  let by = h.said.answer(ByQ)
  if by.isSome and m.isMe(by.get): return none(Value)
  if h.q == m.ownRoom: return some sym"room"
  if h.said.answers(ForQ).exists(n => m.isMe(n)): return some sym"named"
  if h.said.answers(ReQ).exists(d => d in m.mine): return some sym"answer"
  if h.said.isFor(m.speaker.by): return some sym"all"
  none(Value)

proc record(m: Mcp, h: Heard): Value =
  ## (heard Q R READINGS A): an answer as the jam told it, A as said, and
  ## what this session reads in it
  var readings = @[(DigestQ, h.digestOf)]
  let by = h.said.answer(ByQ)
  if by.isSome: readings.add (ByQ, firstName(by.get))
  if h.signer.isSome:
    readings.add (SignerQ, bytes(@(h.signer.get)))
    if h.vouched: readings.add (VouchedQ, firstName(by.get))
  var re: seq[Value]
  for d in h.said.answers(ReQ):
    let k = key(h.q, d)
    if k in m.ranks: re.add toValue(m.ranks[k])
  if re.len > 0: readings.add (ReQ, initList(re))
  let why = m.toYou(h)
  if why.isSome: readings.add (ToYouQ, why.get)
  initRec(@[HeardHead, h.q, toValue(h.rank), initDict(readings), h.said])

proc matching(m: Mcp, a: Asked): seq[Value] =
  ## the records that fit what heard was asked, oldest first
  var found: seq[(int, Value)]
  for h in m.told:
    if h.rank <= a.since: continue
    let r = m.record(h)
    if a.shape.isNone or a.shape.get.fillings(r).next.isSome: found.add (h.rank, r)
  found.sort((x, y) => cmp(x[0], y[0]))
  if a.first > 0: found[0 ..< min(found.len, a.first)].mapIt(it[1])
  else: found[max(0, found.len - a.last) .. ^1].mapIt(it[1])

# ================ what is pushed ================

proc notify(meth: string, params: JsonNode) =
  stdout.write $(%*{"jsonrpc": "2.0", "method": meth, "params": params}) & "\n"
  stdout.flushFile()

proc push(m: Mcp, h: Heard) =
  ## something said to the agent, pushed as a channel
  if m.pushMode == pushNone: return
  if not m.initialized:
    m.pendingPushes.add h
    return
  notify("notifications/claude/channel", %*{
    "content": $m.record(h),
    "meta": {"room": $h.q, "rank": $h.rank, "by": $firstName(h.said.answer(ByQ).get)}})

proc firstHere(m: Mcp): int =
  ## where its name first said it was here, as far as it has been told
  for h in m.c.local.heardIn(HereQ):
    let by = h.said.answer(ByQ)
    if by.isSome and m.isMe(by.get): return h.rank
  m.since

proc catchUp(m: Mcp) =
  ## what was said to it before this line said it was here: pushed if it
  ## wasn't here then, by what the jam says of who came and went, and it
  ## hasn't answered it since. What is only for all, or only heard where
  ## it asks, is pushed only if said since it first came
  let first = m.firstHere
  for h in m.backlog:
    let why = m.toYou(h)
    if h.digestOf notin m.saidRe and not m.c.local.wasHere(m.speaker.by, h.rank) and
       ((why.isSome and why.get != sym"all") or h.rank > first):
      m.push(h)
  m.backlog.setLen 0

proc heard(m: Mcp, h: Heard) =
  m.told.add h
  m.ranks[key(h.q, h.digestOf)] = h.rank
  m.newest = max(m.newest, h.rank)
  if h.q == HereQ and m.since < 0 and h.answer == m.here:
    m.since = h.rank
    m.catchUp()
    return
  let by = h.said.answer(ByQ)
  if by.isNone: return
  if m.isMe(by.get):
    m.mine.add h.digestOf
    for d in h.said.answers(ReQ): m.saidRe.incl d
    return
  if h.said.answer(SaidQ).isNone: return
  if m.toYou(h).isSome or (m.hearAll and h.q in m.asking):
    if m.since < 0 or h.rank < m.since: m.backlog.add h
    else: m.push(h)

# ================ the line to the jam ================

proc reach(m: Mcp): Client =
  ## the line to the jam, dialled again if it has gone, keeping what the
  ## line before was told
  if m.c == nil or m.c.closed:
    m.tried = epochTime()
    m.c = dial(m.place, m.speaker, m.c)
    m.c.onHeard = (h: Heard) => m.heard(h)
    for q in m.asking: m.c.ask q
    m.since = -1
    m.here = m.c.hello()
  m.c

proc keepUp(m: Mcp) =
  ## dials the jam again, every two seconds, once it has gone
  if (m.c == nil or m.c.closed) and epochTime() - m.tried >= 2:
    try: discard m.reach
    except CatchableError: discard

proc settle(ms = 300) =
  ## a moment for the jam to tell what it has
  let until = epochTime() + ms / 1000
  while epochTime() < until: turn(10)

proc ask(m: Mcp, q: Value) =
  if q notin m.asking:
    m.asking.add q
    m.reach.ask q
    settle()
    if m.since >= 0: m.catchUp()

# ================ tools ================

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
      "it back at rank R, and (asked Q N) with how many answers it has told so far.",
     "inputSchema": {"type": "object", "properties": {
       "value": {"type": "string", "description": "one or more values, (Q A) or (Q)"}},
       "required": ["value"]}},
    {"name": "heard", "description":
      "What the jam has told you, oldest first, one per line, each as " &
      "(heard Q R READINGS A): Q the question (a room), R the jam's order, READINGS what " &
      "this session reads in it, {digest: D (what (re D) names) by: NAME signer: KEY " &
      "vouched: NAME re: [R …] to-you: room|named|answer|all}, and A the answer as it was " &
      "said (checked and taken out of its signature, if signed). shape keeps what fits, " &
      "against the whole record. A record or list fits with members to spare, a dict or " &
      "set with entries to spare, and a hole fits only its own mark (a message is a marked " &
      "object): (shape (heard general) {}) is one room, (shape (heard q r {to-you: w}) " &
      "{q r w}) what is said to you, (shape (heard q r x !{(by b) (said (task t))}) " &
      "{q r x b t}) who asked for which task. since keeps what came after a rank; first keeps the oldest " &
      "matching records, or last the newest (default 30); first must be a positive integer, last a " &
      "non-negative integer, and they cannot be combined. wait holds up to that many seconds (at most 600) until something " &
      "comes that fits, after since or, without since, after what has come already.",
     "inputSchema": {"type": "object", "properties": {
       "shape": {"type": "string", "description": "(shape EXAMPLE {HOLE …})"},
       "since": {"type": "integer", "description": "only what came after this rank"},
       "first": {"type": "integer", "minimum": 1,
                 "description": "at most this many, the oldest; cannot combine with last"},
       "last": {"type": "integer", "minimum": 0,
                "description": "at most this many, the newest (default 30); cannot combine with first"},
       "wait": {"type": "number", "description": "seconds to wait for something that fits"}}}}]

proc opens(m: Mcp, q, a: Value): bool =
  ## whether saying `a` in `q` opens a room nobody has listed: a message,
  ## in a question that isn't the jam's own or someone's own room
  if not (a.isObject and a.answer(ByQ).isSome): return false
  if q in [HereQ, GoneQ, RoomsQ, JamQ]: return false
  if q.isKind(bRec, unmarked) and q.len > 0 and q.head in [ForQ, StampsQ]: return false
  not m.c.local.heardIn(RoomsQ).exists(h => h.said == q)

proc tell(m: Mcp, text: string): string =
  let c = m.reach
  var said: seq[string]
  for v in readDocument(text):
    if v.isKind(bRec, unmarked) and v.len notin 1..2:
      raise newException(ValueError, "a jam takes (Q A) to put and (Q) to ask, not " & $v)
    let q = v.items[0]
    m.ask q
    if v.items.len == 1:
      said.add $initRec(@[sym"asked", q, toValue(c.local.heardIn(q).toSeq.len)])
      continue
    let a = v.items[1]
    if m.opens(q, a): discard c.put(RoomsQ, q)
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

proc askedOf(m: Mcp, args: JsonNode): Asked =
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
  result.since = args{"since"}.getInt(if args{"wait"}.getFloat > 0: m.newest else: -1)
  result.last = args{"last"}.getInt(30)

proc lines(found: seq[Value]): string =
  if found.len == 0: "nothing heard fits" else: found.mapIt($it).join("\n")

# ================ MCP ================

proc instructions(m: Mcp): string = """
You are """ & $m.speaker.name & """ on a jam at """ & $m.place & """: a place where people at
terminals, other agents and programs on this machine talk in rooms. Everything said
there can be read by everyone on it, so say things for them, plainly.

You have two tools, both in values. tell hands the jam values exactly as you write
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
    "It arrives as <channel source=\"jam\" room=… rank=… by=…> when channels are on; " &
    "otherwise call heard with a shape for to-you and wait. "
   else:
    "Standard MCP tools provide delivery when you ask. " &
    "Call heard with a shape for to-you and wait to hear new records. ") & """
Say a value (bassline text syntax, e.g. (task "review queries.nim")) when a program should read it."""

proc respond(id: JsonNode, result: JsonNode) =
  stdout.write $(%*{"jsonrpc": "2.0", "id": id, "result": result}) & "\n"
  stdout.flushFile()

proc text(s: string): JsonNode = %*{"content": [{"type": "text", "text": s}]}

proc heardResult(m: Mcp, found: seq[Value]): JsonNode =
  ## the edge's own speaker, place and replay barrier, apart from the values heard
  result = text(lines(found))
  result["_meta"] = %*{"jam": {"name": $m.speaker.name, "place": $m.place,
                                "joinedRank": m.since}}

proc answerWaits(m: Mcp) =
  ## answers each held call once something new fits, its time is up, or
  ## the jam has gone
  var i = 0
  while i < m.waits.len:
    let w = m.waits[i]
    let found = if m.newest > w.asked.since: m.matching(w.asked) else: @[]
    if found.len > 0 or epochTime() >= w.until or m.c == nil or m.c.closed:
      m.waits.delete i
      respond(w.id, m.heardResult(found))
    else: inc i

proc refuse(id: JsonNode, code: int, msg: string) =
  stdout.write $(%*{"jsonrpc": "2.0", "id": id,
                    "error": {"code": code, "message": msg}}) & "\n"
  stdout.flushFile()

proc handle(m: Mcp, msg: JsonNode) =
  let meth = msg{"method"}.getStr
  let id = msg{"id"}
  if id == nil:
    if meth == "notifications/initialized" and not m.initialized:
      m.initialized = true
      for h in m.pendingPushes: m.push(h)
      m.pendingPushes.setLen 0
    return                                 # a notification: nothing to say
  case meth
  of "initialize":
    let capabilities = %*{"tools": {}}
    if m.pushMode == pushClaude:
      capabilities["experimental"] = %*{"claude/channel": {}}
    respond(id, %*{
      "protocolVersion": msg{"params", "protocolVersion"}.getStr("2025-06-18"),
      "capabilities": capabilities,
      "serverInfo": {"name": "jam", "version": Version},
      "instructions": m.instructions})
  of "ping": respond(id, newJObject())
  of "tools/list": respond(id, %*{"tools": tools()})
  of "tools/call":
    let name = msg{"params", "name"}.getStr
    let args = if msg{"params", "arguments"} == nil: newJObject()
               else: msg{"params", "arguments"}
    try:
      case name
      of "tell":
        respond(id, text(m.tell(args{"value"}.getStr)))
      of "heard":
        discard m.reach
        let asked = m.askedOf(args)
        let found = m.matching(asked)
        let wait = min(600.0, args{"wait"}.getFloat)
        if found.len > 0 or wait <= 0: respond(id, m.heardResult(found))
        else:                              # answered later, other calls meanwhile
          m.waits.add Waiting(id: id, asked: asked, until: epochTime() + wait)
      else: raise newException(ValueError, "no tool " & name)
    except CatchableError as e:
      respond(id, %*{"content": [{"type": "text", "text": name & ": " & e.msg}],
                     "isError": true})
  else: refuse(id, -32601, "no method " & meth)

proc run*(t: Tool, a: Args) =
  let pushMode = case a.get("push", "claude")
                 of "claude": pushClaude
                 of "none": pushNone
                 else: t.misuse "--push must be claude or none"
  randomize()
  var speaker = t.speakerFrom(a)
  if not a.has("as") and getEnv("JAM_NAME").len == 0:
    speaker.name = sym("claude-" & toHex(rand(0xFFFF), 4).toLowerAscii)
  let m = Mcp(place: t.placeFrom(a), speaker: speaker, newest: -1, pushMode: pushMode,
              hearAll: a.get("hear", "mine") == "all", saidRe: newBSet(), since: -1)
  let rooms = if a.positional.len > 0: a.positional else: @["general"]
  m.asking = rooms.mapIt(readValue(it))
  try: discard m.reach
  except CatchableError as e:
    chatter "no jam at " & $m.place & " yet (" & e.msg & "); trying again every two seconds"
  var
    pending = ""
    buf = newString(65536)
  while true:
    turn(15)
    m.keepUp()
    m.answerWaits()
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
        except JsonParsingError as e: refuse(newJNull(), -32700, e.msg)
      nl = pending.find('\n')
  if m.c != nil and not m.c.closed: m.c.bye()
