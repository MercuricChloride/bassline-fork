##[
  Conversations. A participant says a value into a conversation, and
  the conversation decides what is passed on: the message as said,
  something of its own, several, or nothing. Everyone in it hears what
  it passes on, the speaker only if the conversation says so. Every
  message is a value said in a conversation, by a participant or by the
  conversation itself.

  A conversation passes on one message to everyone before the next. What
  is said into it while it is passing something on waits its turn, so
  everyone hears in the order it said things. A conversation's `send`
  finishes its own bookkeeping before it says anything, since whoever
  hears may speak into it again.

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
    conv*: Conversation  ## where it was said
    by*: Participant     ## who said it, nil when the conversation says it.
                         ## Only the conversation reaches anyone by it, with `tell`
    value*: Value

  Flag* = enum
    echoes  ## the speaker hears what it said too
    once    ## a value is passed on once, however often it is said

  Passing = tuple
    msg: Msg
    toSpeaker: bool     ## whether its speaker hears it too
    only: Participant   ## the one participant it goes to, or nil for everyone

  Conversation* = ref object of RootObj
    flags*: set[Flag]       ## what the base `send` does
    members: seq[Participant]
    said: BSet              ## what `fresh` has kept
    queue: Deque[Passing]   ## what it has yet to pass on
    passing: bool

  Participant* = ref object of RootObj

  Speaker* = ref object of Participant
    ## a participant that knows the conversations it is in, to speak into them
    convs: seq[Conversation]

  Inbox* = ref object of Speaker
    ## a participant that keeps what it is sent for an async loop to take
    kept: Deque[Msg]
    wake: Future[void]  ## a take waiting for something to be kept

# ================
# Hooks
# ================

method send*(p: Participant, msg: Msg) {.base.} =
  ## hands `msg` to `p`, which must not wait on anything. One that only
  ## speaks takes nothing
  discard

method joined*(p: Participant, c: Conversation) {.base.} =
  ## `p` is now in `c`
  discard

method left*(p: Participant, c: Conversation) {.base.} =
  ## `p` is no longer in `c`, whoever decided it
  discard

method joined*(c: Conversation, p: Participant) {.base.} =
  ## `p` is now in `c`
  discard

method left*(c: Conversation, p: Participant) {.base.} =
  ## `p` is no longer in `c`, whoever decided it
  discard

# ================
# Joining
# ================

proc known*(c: Conversation): seq[Participant] =
  ## who is in `c`
  c.members

proc join*(p: Participant, c: Conversation) =
  if p notin c.members:
    c.members.add p
    p.joined c
    c.joined p

proc leave*(p: Participant, c: Conversation) =
  if p in c.members:
    c.members.keepItIf(it != p)
    p.left c
    c.left p

proc kick*(c: Conversation, p: Participant) =
  ## `c` stops sending to `p` at once, ahead of anything still waiting
  ## its turn to be passed on
  p.leave c

# ================
# Conversation
# ================

proc fresh*(c: Conversation, v: Value): bool =
  ## whether `v` is new to `c`, keeping it if so
  if c.said.isNil: c.said = newBSet()
  result = v notin c.said
  if result: c.said.incl v

proc pass(c: Conversation) =
  ## passes on what is queued, one message before the next
  if c.passing: return
  c.passing = true
  try:
    while c.queue.len > 0:
      let
        next = c.queue.popFirst
        members = c.members  # whoever hears may join or leave meanwhile
      for p in members:
        let hears =
          if next.only.isNil: next.toSpeaker or p != next.msg.by
          else: p == next.only
        if hears and p in c.members:
          try: p.send next.msg
          except CatchableError: c.kick p
  finally:
    c.passing = false

proc reflect*(c: Conversation, msg: Msg, toSpeaker: bool) =
  ## passes `msg` on to everyone in `c`, its speaker only if `toSpeaker`
  c.queue.addLast (msg, toSpeaker, Participant(nil))
  c.pass

proc say*(c: Conversation, v: Value) =
  ## `c` says `v` itself, to everyone in it
  c.reflect(Msg(conv: c, value: v), toSpeaker = true)

proc say*(c: Conversation, values: openArray[Value]) =
  ## `c` says each of `values` itself, in order, with nothing said into it
  ## meanwhile coming between them
  for v in values: c.queue.addLast (Msg(conv: c, value: v), true, Participant(nil))
  c.pass

proc tell*(c: Conversation, p: Participant, values: openArray[Value]) =
  ## `c` says each of `values` to `p` alone, in order, if `p` is in it
  for v in values: c.queue.addLast (Msg(conv: c, value: v), true, p)
  c.pass

method send*(c: Conversation, msg: Msg): bool {.base.} =
  ## a message said into `c`, answering whether `c` took it. It must not
  ## raise. By default it is passed on as said: once if `once`, to its
  ## speaker too if `echoes`
  if once notin c.flags or c.fresh msg.value:
    c.reflect(msg, echoes in c.flags)
  true

proc say*(p: Participant, c: Conversation, v: Value): bool =
  ## `p` says `v` into `c`, answering whether `c` took it
  c.send Msg(conv: c, by: p, value: v)

# ================
# Speaker
# ================

proc convs*(s: Speaker): seq[Conversation] =
  ## the conversations `s` is in
  s.convs

method joined*(s: Speaker, c: Conversation) =
  s.convs.add c

method left*(s: Speaker, c: Conversation) =
  s.convs.keepItIf(it != c)

proc say*(s: Speaker, v: Value, but: Conversation = nil) =
  ## `s` says `v` into every conversation it is in, but `but`
  let convs = s.convs  # a conversation may kick it meanwhile
  for c in convs:
    if c != but and c in s.convs:
      try: discard s.say(c, v)
      except CatchableError: s.leave c

proc leaveAll*(s: Speaker) =
  for c in s.convs.toSeq: s.leave c

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
