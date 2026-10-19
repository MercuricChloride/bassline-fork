##[
  Conversations. A participant says a value into a conversation, and
  the conversation decides what is passed on: the message as said,
  something of its own, several, or nothing. Everyone in it hears what
  it passes on, the speaker only if the conversation says so. Every
  message is a value said in a conversation, by a participant in it or
  by the conversation itself.

  Whoever holds a conversation holds what it can do: say as it, tell
  one participant, pass a message on, kick. Everyone else holds a
  `Room`, the conversation as those in it hold it, to join, leave, say
  into and tell apart from another. A message carries its room and what
  the conversation calls its speaker, a value, so hearing something
  gives no hold on the conversation or on whoever said it. Only those
  in a conversation speak into it, and the conversation decides who
  gets in and what it calls them.

  A conversation passes on one message to everyone before the next. What
  is said into it while it is passing something on waits its turn, so
  everyone hears in the order it said things.

  Deciding what to do with something said is one transaction. Whatever
  is said or told while it is decided is passed on only once it is
  taken, and whatever is kept for it (`keep`) is kept only then, before
  anything is passed on. If it is refused, nothing said or kept for it
  stands. One transaction spans every conversation it reaches, so a
  conversation that says into another while deciding takes or refuses
  for both. Its rule sees what was kept before the transaction began.

  A conversation's rule is a proc like its `send`, taking a message and
  answering whether it was taken. Rules are put together with `all`,
  where every rule must take it, and `first`, where the first to take it
  decides.

  Sending to a participant never waits on it, and keeping up is the
  participant's business. How it keeps up is its own: an `Inbox` keeps
  what it hasn't taken yet for an async loop, and others act on what
  they're sent right away. A participant whose `send` raises is kicked,
  and a speaker leaves a conversation whose `send` raises.
]##
import std/[asyncdispatch, deques, sequtils]
import ../core

export asyncdispatch

discard getGlobalDispatcher()  # so a completed future's callbacks wait their turn

type
  Msg* = object
    room*: Room   ## where it was said
    by*: Value    ## what the conversation calls whoever said it, nil when
                  ## it says it itself
    value*: Value

  Room* = object
    ## a conversation as those in it hold it
    conv: Conversation

  Seat = tuple
    p: Participant
    name: Value

  Passing = tuple
    msg: Msg
    toSpeaker: bool  ## whether its speaker hears it too
    only: Value      ## the name of the one it goes to, or nil for everyone

  Rule* = proc(c: Conversation, msg: Msg): bool
    ## decides `msg` in `c`, answering whether it was taken

  Conversation* = ref object of RootObj
    rule*: Rule             ## what the base `send` does, or nil to pass
                            ## everything on as said
    names*: proc(p: Participant): Value  ## what `nameFor` answers, or nil
                                         ## to name by the order seated
    seats: seq[Seat]
    seated: int             ## how many it has seated, to name the next
    queue: Deque[Passing]   ## what it has yet to pass on
    passing: bool

  Refusal = tuple
    c: Conversation  ## nil when nothing was refused with words
    name, v: Value   ## who to tell, and what

  Transaction = object
    depth: int                    ## how many decisions are open
    keeps: seq[proc() {.closure.}]
    touched: seq[(Conversation, int)]  ## said into, and how much it had queued before
    refusal: Refusal

  Participant* = ref object of RootObj

  Speaker* = ref object of Participant
    ## a participant that knows the rooms it is in, to speak into them
    rooms: seq[Room]

  Inbox* = ref object of Speaker
    ## a participant that keeps what it is sent for an async loop to take
    kept: Deque[Msg]
    wake: Future[void]  ## a take waiting for something to be kept

# ================
# Rooms
# ================

converter room*(c: Conversation): Room =
  ## `c` as those in it hold it
  Room(conv: c)

proc `==`*(a, b: Room): bool = a.conv == b.conv

proc seat(c: Conversation, p: Participant): int =
  ## where `p` sits in `c`, or -1. An empty room seats nobody
  if c.isNil: return -1
  for i, s in c.seats:
    if s.p == p: return i
  -1

proc contains*(r: Room, p: Participant): bool =
  ## whether `p` is in `r`
  r.conv.seat(p) >= 0

proc nameOf*(r: Room, p: Participant): Value =
  ## what `r` calls `p`, or nil if `p` isn't in it. Only whoever holds
  ## `p` can ask, so a participant can know its own words
  let i = r.conv.seat(p)
  if i >= 0: r.conv.seats[i].name else: Value()

# ================
# Hooks
# ================

method send*(p: Participant, msg: Msg) {.base.} =
  ## hands `msg` to `p`, which must not wait on anything. One that only
  ## speaks takes nothing
  discard

method joined*(p: Participant, r: Room) {.base.} =
  ## `p` is now in `r`
  discard

method left*(p: Participant, r: Room) {.base.} =
  ## `p` is no longer in `r`, whoever decided it
  discard

method admits*(c: Conversation, p: Participant): bool {.base.} =
  ## whether `p` may join `c`. By default anyone may
  true

method nameFor*(c: Conversation, p: Participant): Value {.base.} =
  ## what `c` will call `p` once it is in, never nil. By default `names`,
  ## or the order it was seated in
  if c.names.isNil: num(c.seated) else: c.names(p)

method joined*(c: Conversation, name: Value) {.base.} =
  ## whoever `c` calls `name` is now in it
  discard

method left*(c: Conversation, name: Value) {.base.} =
  ## whoever `c` called `name` is no longer in it, whoever decided it
  discard

# ================
# Joining
# ================

proc known*(c: Conversation): seq[Value] =
  ## what `c` calls each participant in it
  c.seats.mapIt(it.name)

proc member*(c: Conversation, name: Value): Participant =
  ## whoever `c` calls `name`, or nil
  for s in c.seats:
    if s.name == name: return s.p

proc join*(p: Participant, r: Room): bool {.discardable.} =
  ## `p` joins `r` if the conversation admits it under a name nobody in
  ## it has, answering whether `p` is in it
  let c = r.conv
  if c.isNil: return false
  if p in r: return true
  if not c.admits(p): return false
  let name = c.nameFor(p)
  if name.kind == bNil or name in c.known: return false
  inc c.seated
  c.seats.add (p, name)
  p.joined r
  c.joined name
  true

proc leave*(p: Participant, r: Room) =
  let c = r.conv
  let i = c.seat(p)
  if i >= 0:
    let name = c.seats[i].name
    c.seats.delete i
    p.left r
    c.left name

proc kick*(c: Conversation, name: Value) =
  ## `c` stops sending to whoever it calls `name` at once, ahead of
  ## anything still waiting its turn to be passed on
  let p = c.member(name)
  if not p.isNil: p.leave c

proc kick*(c: Conversation, p: Participant) =
  ## `c` stops sending to `p`, for whoever holds both
  p.leave c

# ================
# Conversation
# ================

var tx: Transaction  # the one being decided, if any

proc queue(c: Conversation, p: Passing) =
  if tx.depth > 0 and not tx.touched.anyIt(it[0] == c):
    tx.touched.add (c, c.queue.len)
  c.queue.addLast p

template keep*(c: Conversation, body: untyped) =
  ## does `body` once what `c` is deciding is taken, or now if nothing is
  ## being decided. Values it uses are best bound with `let` first
  if tx.depth > 0: tx.keeps.add(proc() = body)
  else: body

proc pass(c: Conversation) =
  ## passes on what is queued, one message before the next
  if c.passing or tx.depth > 0: return
  c.passing = true
  try:
    while c.queue.len > 0:
      let
        next = c.queue.popFirst
        seats = c.seats  # whoever hears may join or leave meanwhile
      for s in seats:
        let hears =
          if next.only.kind == bNil: next.toSpeaker or s.name != next.msg.by
          else: s.name == next.only
        if hears and s.p in c:
          try: s.p.send next.msg
          except CatchableError: s.p.leave c
  finally:
    c.passing = false

proc reflect*(c: Conversation, msg: Msg, toSpeaker: bool) =
  ## passes `msg` on to everyone in `c`, its speaker only if `toSpeaker`
  c.queue (msg, toSpeaker, Value())
  c.pass

proc say*(c: Conversation, v: Value) =
  ## `c` says `v` itself, to everyone in it
  c.reflect(Msg(room: c, value: v), toSpeaker = true)

proc say*(c: Conversation, values: openArray[Value]) =
  ## `c` says each of `values` itself, in order, with nothing said into it
  ## meanwhile coming between them
  for v in values: c.queue (Msg(room: c, value: v), true, Value())
  c.pass

proc tell*(c: Conversation, name: Value, values: openArray[Value]) =
  ## `c` says each of `values` to whoever it calls `name` alone, in order
  for v in values: c.queue (Msg(room: c, value: v), true, name)
  c.pass

proc refuse*(c: Conversation, msg: Msg, v: Value): bool =
  ## refuses `msg`, telling whoever said it `v` once what was said and
  ## kept for it is undone. Answers false
  if tx.depth > 0: tx.refusal = (c, msg.by, v)
  else: c.tell(msg.by, [v])
  false

proc trying(c: Conversation, msg: Msg, rule: Rule, words: bool,
            refusal: var Refusal): bool =
  ## `rule` decides `msg` in `c` as part of the open transaction, or as
  ## one of its own. If it refuses, what was said and kept for it is
  ## undone, and its words of refusal are told if `words`, and left in
  ## `refusal` either way
  let
    keeps = tx.keeps.len
    touched = tx.touched.len
    queued = tx.touched.mapIt(it[0].queue.len)
    before = tx.refusal
  tx.refusal = (nil, Value(), Value())
  inc tx.depth
  try: result = rule(c, msg)
  except CatchableError: result = false
  if not result:
    for i, (t, at) in tx.touched:
      let n = if i < touched: queued[i] else: at
      t.queue.shrink(fromLast = t.queue.len - n)
    tx.touched.setLen touched
    tx.keeps.setLen keeps
  elif tx.depth == 1:
    var i = 0
    while i < tx.keeps.len:  # a keep may keep more
      tx.keeps[i]()
      inc i
  refusal = tx.refusal
  tx.refusal = before
  dec tx.depth
  if words and not result and not refusal.c.isNil:
    refusal.c.tell(refusal.name, [refusal.v])
  if tx.depth == 0:
    let touched = move tx.touched
    tx.keeps.setLen 0
    for (t, _) in touched: t.pass

method send*(c: Conversation, msg: Msg): bool {.base.} =
  ## a message said into `c`, answering whether `c` took it. It must not
  ## raise. By default `c`'s rule decides, or it is passed on as said
  if c.rule.isNil:
    c.reflect(msg, toSpeaker = false)
    true
  else: c.rule(c, msg)

proc sending(c: Conversation, msg: Msg): bool = c.send msg

proc say*(p: Participant, r: Room, v: Value): bool {.discardable.} =
  ## `p` says `v` into `r`, answering whether the conversation took it.
  ## One not in it is refused
  let i = r.conv.seat(p)
  if i < 0: return false
  let msg = Msg(room: r, by: r.conv.seats[i].name, value: v)
  var refusal: Refusal
  r.conv.trying(msg, sending, words = true, refusal)

# ================
# Rules
# ================

proc all*(rules: varargs[Rule]): Rule =
  ## every one of `rules` must take a message, in order
  let rules = @rules
  result = proc(c: Conversation, msg: Msg): bool =
    for r in rules:
      if not r(c, msg): return false
    true

proc first*(rules: varargs[Rule]): Rule =
  ## the first of `rules` to take a message decides it. What the others
  ## said and kept for it is undone. A rule that doesn't know a message
  ## refuses it without words, and if none takes it the last words of
  ## refusal stand
  let rules = @rules
  result = proc(c: Conversation, msg: Msg): bool =
    var last: Refusal
    for r in rules:
      var refusal: Refusal
      if c.trying(msg, r, words = false, refusal): return true
      if not refusal.c.isNil: last = refusal
    if not last.c.isNil: tx.refusal = last
    false

proc asSaid*(toSpeaker = false): Rule =
  ## passes a message on as said
  result = proc(c: Conversation, msg: Msg): bool =
    c.reflect(msg, toSpeaker)
    true

# ================
# Speaker
# ================

proc rooms*(s: Speaker): seq[Room] =
  ## the rooms `s` is in
  s.rooms

method joined*(s: Speaker, r: Room) =
  s.rooms.add r

method left*(s: Speaker, r: Room) =
  s.rooms.keepItIf(it != r)

proc say*(s: Speaker, v: Value, but = Room()) =
  ## `s` says `v` into every room it is in, but `but`
  let rooms = s.rooms  # a conversation may kick it meanwhile
  for r in rooms:
    if r != but and r in s.rooms:
      try: discard s.say(r, v)
      except CatchableError: s.leave r

proc leaveAll*(s: Speaker) =
  for r in s.rooms.toSeq: s.leave r

# ================
# Inbox
# ================

method send*(p: Inbox, msg: Msg) =
  p.kept.addLast msg
  if not p.wake.isNil:
    let f = p.wake
    p.wake = nil
    f.complete

proc take*(p: Inbox): Future[Msg] {.async.} =
  ## the next message sent to `p`. One given up on takes nothing
  while p.kept.len == 0:
    if p.wake.isNil: p.wake = newFuture[void]("take")
    await p.wake
  return p.kept.popFirst

template each*(p: Inbox, msg, body: untyped) =
  ## takes every message sent to `p`, one at a time
  while true:
    let msg = await p.take
    body

# ================
# Msg
# ================

proc reply*(self: Participant, msg: Msg, val: sink Value): bool {.discardable.} =
  self.say(msg.room, val)