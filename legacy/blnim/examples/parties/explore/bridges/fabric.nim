##[
  Parties on many machines carrying topics between them, while every
  program only attends its own.

  Each party has a gate: a program on its machine that owns the topics
  (fabric in) and (fabric out) there. A bridge attends two parties and
  says into (fabric in) at each what it hears in (fabric out) at the
  other. Since the gate owns both topics, what a bridge says reaches the
  gate alone, and only the gate's words reach the bridges.

  What crosses is (carried P N S T V): at the party that goes by P, in its
  order N, S said V into T. P and N tell one saying from every other, so
  a gate takes each once, says it on into its own (fabric out) for the
  bridges there, and drops it when it comes round again. A ring or a mesh
  of bridges then brings every saying to every party once.

  A gate says V into T at its party from a seat: a connection of its own
  standing for S at P, one for each far speaker. Programs hear far
  speakers as they hear near ones, by a name of this party, and what they
  say into that name goes back as (carried P' N' S' (seat P S) R), which
  the gate at P says into S from a seat standing for S'. When the party at
  P says (dead S), every gate holding a seat for S lets it go.

  An owned topic has a home: the machine whose gate is given it among its
  `topics`, where a program owns it. Every other gate given it as `owned`
  holds it for that owner, from a seat that owns the topic at its party.
  What is said there into the topic, or into the holding seat, goes as
  (carried P N S (owner T) V) to the home, where a seat says it into T
  and so to whoever owns T there when it arrives. What the owner says
  comes back to every party from the holding seats.

  A party with no gate swallows what bridges say into it, since nobody
  else hears (fabric in) and nobody but an owner speaks in (fabric out).
]##
import std/tables
import bl/core
import bl/parties/parties

export parties

blet"{status}"

let
  fabricIn* = bl"(fabric in)"
  fabricOut* = bl"(fabric out)"

# ================
# Gates
# ================

type Gate* = ref object
  at: IpAddress
  port: Port
  topics: seq[Value]               ## what crosses this gate, either way
  owned: seq[Value]                ## topics owned at another machine
  main*: Attendee                  ## owns the fabric topics, hears `topics` and status
  party*: Value                    ## what the party goes by, nil until known
  seen: BSet                       ## [P N] of every saying sent out
  spoke: BSet                      ## near speakers whose sayings went out
  seats*: Table[string, Attendee]  ## a seat for each far speaker, by (seat P S) as CE
  seatNames: BSet                  ## every name a seat has gone by
  holders: Table[string, Attendee] ## a seat owning each owned topic, by its CE
  admitted*, dropped*: int

proc isSeat(g: Gate, s: Value): bool =
  if s in g.seatNames: return true
  for a in g.seats.values:
    if a.name == s: return true
  for a in g.holders.values:
    if a.name == s: return true

proc spread(g: Gate, p, n, s, t, v: Value) =
  ## says a saying into (fabric out), for every bridge at this party
  g.seen.incl bl"[$p $n]"
  if p == g.party and s.kind != bNil: g.spoke.incl s
  g.main.say(fabricOut, bl"(carried $p $n $s $t $v)")

proc hearing(g: Gate, seat: Attendee, p, s: Value) {.async.} =
  ## what is said into a seat, sent back to the far speaker it stands for
  seat.each msg:
    if msg.by.kind != bNil:
      let n = msg.n
      g.spread(msg.party, n.toValue, msg.by, bl"(seat $p $s)", msg.value)
    else:
      matchValue msg.value:
      of "(name $name)": g.seatNames.incl name
      else: discard

proc seatFor(g: Gate, p, s: Value): Attendee =
  let k = bl"(seat $p $s)".ce.toString
  result = g.seats.getOrDefault(k)
  if result.isNil:
    result = attend(g.at, g.port)
    g.seats[k] = result
    asyncCheck g.hearing(result, p, s)

proc hold(g: Gate, seat: Attendee, t: Value) {.async.} =
  ## what is said here into a topic owned elsewhere, or into the seat
  ## holding it, sent home to whoever owns it there when it arrives
  seat.each msg:
    let n = msg.n.toValue
    if msg.by.kind == bNil:
      matchValue msg.value:
      of "(name $name)": g.seatNames.incl name
      else: discard
    elif not g.isSeat(msg.by): g.spread(msg.party, n, msg.by, bl"(owner $t)", msg.value)

proc letGo(g: Gate, p, s: Value) =
  let k = bl"(seat $p $s)".ce.toString
  if k in g.seats:
    g.seats[k].close
    g.seats.del k

proc admit(g: Gate, e: Value) =
  ## a saying a bridge brought: said here once, and sent on
  matchValue e:
  of "(carried $p $n $s $t $v)":
    if p == g.party or bl"[$p $n]" in g.seen:
      inc g.dropped
      return
    inc g.admitted
    g.spread(p, n, s, t, v)
    matchValue t:
    of "(seat $dp $ds)":
      if dp == g.party: g.seatFor(p, s).say(ds, v)
    of "(owner $ot)":
      if ot in g.topics: g.seatFor(p, s).say(ot, v)
    elif t == status:
      matchValue v:
      of "(dead $who)": g.letGo(p, who)
      else: discard
    elif t in g.owned: g.holders[t.ce.toString].say(t, v)
    elif t in g.topics: g.seatFor(p, s).say(t, v)
  else: discard

proc run(g: Gate) {.async.} =
  g.main.each msg:
    let n = msg.n.toValue
    if msg.topic == fabricIn: g.admit msg.value
    elif msg.topic == status:
      matchValue msg.value:
      of "(dead $who)":
        if who in g.spoke: g.spread(msg.party, n, msg.by, status, msg.value)
      else: discard
    elif msg.by.kind == bNil: g.party = msg.party  # (name S), or (invalid X) when refused
    elif not g.isSeat(msg.by): g.spread(msg.party, n, msg.by, msg.topic, msg.value)

proc gate*(at: IpAddress, port: Port, topics: seq[Value], owned: seq[Value] = @[]): Gate =
  ## the gate of the party at `at` and `port`, carrying `topics`, and
  ## holding `owned` for owners on other machines
  result = Gate(at: at, port: port, topics: topics, owned: owned, seen: newBSet(),
                spoke: newBSet(), seatNames: newBSet(),
                main: attend(at, port, owns = @[fabricIn, fabricOut]))
  for t in topics: result.main.sub t
  result.main.sub status
  for t in owned:
    let seat = attend(at, port, owns = @[t])
    result.holders[t.ce.toString] = seat
    asyncCheck result.hold(seat, t)
  asyncCheck result.run

proc close*(g: Gate) =
  g.main.close
  for a in g.seats.values: a.close
  for a in g.holders.values: a.close

# ================
# Bridges
# ================

type Bridge* = ref object
  ends: array[2, Attendee]
  parties: array[2, Value]  ## what each end's party goes by
  topics: seq[Value]        ## what it carries, everything when empty
  carried*: array[2, int]   ## from end 0 to end 1, and back

proc carries(b: Bridge, e: Value): bool =
  if b.topics.len == 0: return true
  matchValue e:
  of "(carried $_ $_ $_ (seat $_ $_) $_)": true
  of "(carried $_ $_ $_ (owner $t) $_)": t in b.topics
  of "(carried $_ $_ $_ $t $_)": t == status or t in b.topics
  else: false

proc close*(b: Bridge) =
  for a in b.ends: a.close

proc carrying(b: Bridge, i: int) {.async.} =
  let (src, dst) = (b.ends[i], b.ends[1 - i])
  src.each msg:
    if msg.topic == fabricOut:
      if b.carries(msg.value):
        dst.say(fabricIn, msg.value)
        inc b.carried[i]
    elif msg.by.kind == bNil:
      b.parties[i] = msg.party
      if b.parties[1 - i] == msg.party: b.close  # both ends at one party

proc bridge*(a: (IpAddress, Port), b: (IpAddress, Port), topics: seq[Value] = @[]): Bridge =
  ## a bridge between the parties at `a` and `b`, carrying `topics`
  result = Bridge(ends: [attend(a[0], a[1]), attend(b[0], b[1])], topics: topics)
  for i in 0 .. 1:
    result.ends[i].sub fabricOut
    asyncCheck result.carrying(i)

proc isClosed*(b: Bridge): bool = b.ends[0].isClosed

# ================
# Finding parties
# ================

proc probe*(at: IpAddress, port: Port, wait = 500): Future[Value] {.async.} =
  ## what the party at `at` and `port` goes by, or nil if none is there
  ## within `wait` ms. A party speaks first, so finding one asks nothing
  let a = attend(at, port)
  if await a.ready.withTimeout(wait):
    let first = await a.next
    if first.isSome: result = first.get.party
  a.close

when isMainModule:
  ## fabric serve | gate PORT TOPIC… | bridge PORT PORT | hear PORT TOPIC | say PORT TOPIC V
  ##
  ## Each a program of its own, at parties on [::1]. Topics and values are
  ## in the textual syntax.
  import std/[os, sequtils, strutils]
  let
    args = commandLineParams()
    here = parseIpAddress("::1")
  proc at(i: int): (IpAddress, Port) = (here, Port(args[i].parseInt))
  case (if args.len > 0: args[0] else: "")
  of "serve":
    echo serve(here, Port(0)).port
    runForever()
  of "gate":
    discard gate(here, at(1)[1], args[2 .. ^1].mapIt(it.readValue))
    runForever()
  of "bridge":
    discard bridge(at(1), at(2))
    runForever()
  of "hear":
    let a = attend(here, at(1)[1])
    a.sub args[2].readValue
    proc hearing() {.async.} =
      a.each msg:
        if msg.by.kind != bNil: echo msg.value
    waitFor hearing()
  of "say":
    let a = attend(here, at(1)[1])
    a.say(args[2].readValue, args[3].readValue)
    waitFor a.ready
    waitFor sleepAsync(100)
  else: quit "fabric serve | gate PORT TOPIC… | bridge PORT PORT | hear PORT TOPIC | say PORT TOPIC V"
