##[
  The party a program is at without asking: `party`, attending the party
  at the place of `bassline` on port 8455, or at the address in
  `BL_PARTY`, or wherever `-d:partyAt` and `-d:partyPort` say. It
  connects once the program runs its dispatcher, and again whenever its
  connection goes. What it owns (`owns`) is set before the dispatcher
  runs.

  A value is a topic at it. `t.say v` says `v` into `t`, `t.sub` and
  `t.unsub` start and stop hearing it, and `t.hear` and `t.each` take
  what is said into it, hearing it from then on. `t.unsub` ends the
  loops taking from `t`, and a hear after it hears `t` again. A hear
  given up on with `abort` takes nothing, and gives back what it was
  handed. Several topics can be taken from at once, each by its own
  loop.

  `me` stands for whatever the program goes by, which changes with each
  connection. `me.each` takes what is said into it on every connection,
  and the party says (name S) into it as each connection begins, so a
  program can tell others where it is now.

  A program takes from its topics or from `party` itself (`party.each`),
  and not both, since only one may take from `party` at a time. Each
  topic keeps at most `MaxKept` things nobody has taken, letting the
  oldest go.
]##
import std/[deques, os, tables]
import ../core
import ./parties

export parties

const
  partyAt {.strdefine.} = ""
  partyPort {.intdefine.} = int(PartyPort)
  MaxKept* {.intdefine.} = 10_000

proc placed(): IpAddress =
  let at = getEnv("BL_PARTY", partyAt)
  if at == "": placeOf(bl"bassline") else: parseIpAddress(at)

let
  party* = attend(placed(), Port(partyPort))
  me* = bytes(newSeq[byte]())  ## stands for whatever the program goes by

proc meant(topic: Value): Value =
  ## the topic at the party that `topic` stands for
  if topic == me: party.name else: topic

proc say*(topic, v: Value): bool {.discardable.} =
  ## says `v` into `topic`
  party.say(topic.meant, v)

proc sub*(topic: Value) =
  ## hears `topic` from now on
  if topic != me: party.sub topic

type Chan = ref object
  ## what has been said into one topic and not yet taken, and the hears
  ## waiting to take it
  kept: Deque[Said]
  takers: seq[Future[Said]]  ## oldest first
  dropped: bool              ## whether the topic has been let go

var
  chans: Table[string, Chan]  ## by the topic's CE
  sorting = false

proc keyOf(topic: Value): string =
  if topic == me or (party.name.kind != bNil and topic == party.name): me.ce.toString
  else: topic.ce.toString

proc drop(c: Chan, why: string) =
  ## lets `c` go, telling every hear waiting on it that nothing more will come
  c.dropped = true
  for f in c.takers: f.fail newException(IOError, why)
  c.takers.setLen 0

proc unsub*(topic: Value) =
  ## stops hearing `topic`, ending the loops taking from it
  if topic == me: return
  party.unsub topic
  let k = topic.keyOf
  if chans.hasKey(k):
    chans[k].drop "unsubscribed"
    chans.del k

proc give(c: Chan, said: Said) =
  ## hands `said` to the oldest hear waiting, or keeps it
  if c.takers.len > 0:
    let f = c.takers[0]
    c.takers.delete 0
    f.complete said
  else:
    if c.kept.len >= MaxKept: c.kept.popFirst
    c.kept.addLast said

proc sort() {.async.} =
  ## hands each thing `party` hears to its topic's channel, and once the
  ## party is closed tells every hear waiting that nothing more will come
  party.each said:
    let c = chans.getOrDefault(said.topic.keyOf)
    if not c.isNil: c.give said
  for c in chans.values: c.drop "the party is closed"

proc chan(topic: Value): Chan =
  let k = topic.keyOf
  result = chans.getOrDefault(k)
  if result.isNil:
    result = Chan()
    chans[k] = result
    if k != me.ce.toString: topic.sub
  if not sorting:
    sorting = true
    asyncCheck sort()

proc hear(c: Chan): Future[Said] =
  result = newFuture[Said]("hear")
  if c.kept.len > 0: result.complete c.kept.popFirst
  elif c.dropped: result.fail newException(IOError, "unsubscribed")
  elif party.isClosed: result.fail newException(IOError, "the party is closed")
  else: c.takers.add result

proc hear*(topic: Value): Future[Said] =
  ## the next thing said into `topic`, hearing it from now on
  topic.chan.hear

proc abort*(f: Future[Said]) =
  ## gives up on a hear. It takes nothing from now on, and what it was
  ## handed already goes back to its channel, first in line
  if f.finished:
    if f.failed: return
    let c = chans.getOrDefault(f.read.topic.keyOf)
    if c.isNil: return
    if c.takers.len > 0: c.give f.read
    else: c.kept.addFirst f.read
    return
  for c in chans.values:
    let i = c.takers.find f
    if i >= 0:
      c.takers.delete i
      return

template each*(topic: Value, msg, body: untyped) =
  ## takes everything said into `topic`, one at a time, until it is let
  ## go or the party is closed
  let c = topic.chan
  while not c.dropped:
    var next: Said
    try: next = await c.hear
    except IOError: break
    let msg = next
    body
