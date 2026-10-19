##[
  A party in a topic. Whoever owns a topic T at a party hears everything
  said into T, and is told who said it, so it can play inside T the part
  the party plays for its connections. `host` does that: it runs a party
  of its own inside T, with names, topics, owners and `status`, in the
  party's own dialect, one level down.

  Inside T a connection is whoever says into T. It says (say T X), X
  what it would say to a party, and the owner tells it what a party
  would write to it by saying that into what it goes by outside.
  Arriving and going are a connection's beginning and end, and inside T
  there is no connection, so they take two words more: (arrive), said
  into T first, and (gone), told when the owner lets a seat go. A seat
  ends when its connection outside does, as the party outside says in
  `status`.

  The party inside lasts as long as the owner's connection outside.
  When that goes, everyone inside has gone too, and arrives again at
  whoever owns T next.

  `bridge` makes the party in T a party at an address, so a program
  written for a party attends it unchanged: each connection to the
  bridge is a connection to the party outside that arrives in T and
  passes values each way.
]##
import std/[sets, sysrand, tables]
import bl/core
import bl/parties/parties

export parties

blet"{status}"

proc key(v: Value): string = v.ce.toString

# ================
# The owner
# ================

type
  Seat = ref object
    outer: Value  ## what its connection goes by outside
    name: Value   ## what it goes by inside
    hears, owns: seq[Value]
    spoke, gone: bool

  Host* = ref object
    outside*: Attendee                ## the owner, at the party outside
    topic: Value
    name*: Value                      ## what the party inside goes by
    said: int
    seats: seq[Seat]
    outers: Table[string, Seat]       ## each seat by what it goes by outside
    letGo: HashSet[string]            ## outside names let go and not yet dead
    hearers: Table[string, seq[Seat]]
    owners: Table[string, Seat]       ## nil for the party inside

proc next(h: Host): int =
  inc h.said
  h.said

proc tell(h: Host, s: Seat, v: Value) =
  ## writes `v` to `s`, as a party writes to a connection
  h.outside.say(s.outer, v)

proc sayTo(h: Host, hearers: seq[Seat], t, v, by: Value, but: Seat = nil) =
  let n = h.next
  for o in hearers:
    if o != but: h.tell(o, bl"(said $n $t $v $by)")

proc say(h: Host, t, v, by: Value, but: Seat = nil) =
  h.sayTo(h.hearers.getOrDefault(t.key), t, v, by, but)

proc unhear(h: Host, s: Seat, t: Value) =
  let i = s.hears.find t
  if i < 0: return
  s.hears.del i
  let k = t.key
  h.hearers[k].del h.hearers[k].find(s)
  if h.hearers[k].len == 0: h.hearers.del k

proc hear(h: Host, s: Seat, t: Value) =
  if t in s.hears: return
  s.hears.add t
  h.hearers.mgetOrPut(t.key, @[]).add s
  if t == status:
    for o in h.seats:
      let name = o.name
      if o != s: h.sayTo(@[s], t, bl"(alive $name)", Value())

proc leave(h: Host, s: Seat) =
  if s.gone: return
  s.gone = true
  let (hears, name) = (s.hears, s.name)
  for t in hears: h.unhear(s, t)
  for t in s.owns: h.owners.del t.key
  h.seats.del h.seats.find(s)
  h.outers.del s.outer.key
  h.say(status, bl"(dead $name)", Value())

proc own(h: Host, s: Seat, said, topics: Value) =
  if s.spoke or topics.kind != bSet:
    h.say(s.name, bl"(invalid $said)", Value())
    return
  for t in topics.els:
    if h.owners.hasKey(t.key):
      h.say(s.name, bl"(invalid $said)", Value())
      h.tell(s, bl"(gone)")
      h.letGo.incl s.outer.key
      h.leave s
      return
  for t in topics.els:
    h.owners[t.key] = s
    s.owns.add t

proc sayFrom(h: Host, s: Seat, said, t, v: Value) =
  let k = t.key
  if not h.owners.hasKey(k) or h.owners[k] == s: h.say(t, v, s.name, but = s)
  elif h.owners[k].isNil: h.say(s.name, bl"(invalid $said)", Value())
  else: h.sayTo(@[h.owners[k]], t, v, s.name)

proc seat(h: Host, outer: Value): Seat =
  let s = Seat(outer: outer, name: bytes(urandom 16))
  let (n, name, party) = (h.next, s.name, h.name)
  h.seats.add s
  h.outers[outer.key] = s
  h.tell(s, bl"(name $n $name $party)")
  h.hear(s, name)
  h.say(status, bl"(alive $name)", Value(), but = s)
  s

proc heard(h: Host, outer, said: Value) =
  ## what the connection that goes by `outer` outside said into the topic
  if outer.key in h.letGo: return
  var s = h.outers.getOrDefault(outer.key)
  if s.isNil:
    s = h.seat(outer)
    if said == bl"(arrive)": return
  matchValue said:
  of "(own $topics)": h.own(s, said, topics)
  of "(sub $t)": h.hear(s, t)
  of "(unsub $t)": h.unhear(s, t)
  of "(say $t $x)": h.sayFrom(s, said, t, x)
  else: h.say(s.name, bl"(invalid $said)", Value())
  s.spoke = true

proc begin(h: Host) =
  ## a new connection outside, so a new party inside
  h.name = bytes(urandom 16)
  h.said = 0
  h.seats.setLen 0
  h.outers.clear
  h.letGo.clear
  h.hearers.clear
  h.owners.clear
  h.owners[status.key] = nil

proc hosting(h: Host) {.async.} =
  h.outside.each msg:
    if msg.by.kind == bNil:
      matchValue msg.value:
      of "(name $_)": h.begin
      of "(dead $o)":
        let s = h.outers.getOrDefault(o.key)
        if not s.isNil: h.leave s
        h.letGo.excl o.key
      else: discard
    elif msg.topic == h.topic: h.heard(msg.by, msg.value)

proc host*(at: IpAddress, port: Port, topic: Value): Host =
  ## a party inside `topic`, hosted by a program that owns it at the
  ## party at `at` and `port`, or tries to until it does
  result = Host(outside: attend(at, port, owns = @[topic]), topic: topic)
  result.outside.sub status
  asyncCheck result.hosting

proc close*(h: Host) = h.outside.close

proc seated*(h: Host): int = h.seats.len

# ================
# The bridge
# ================

const KnockWait* = 500  ## ms a door waits for whoever owns its topic to answer

proc reading(socket: AsyncSocket, each: proc(v: Value)) {.async.} =
  ## hands `each` every value `socket` sends, until it ends or sends
  ## bytes that are not CE
  var d = newDecoder()
  while not socket.isClosed:
    try:
      let data = await socket.recv(16 * 1024, flags = {})
      if data.len == 0: return
      d.buf.add data.toBytes
      for view in d.checked: each view.toValue
      d.compact
    except CatchableError:
      return

proc door(at: IpAddress, port: Port, topic: Value, socket: AsyncSocket) {.async.} =
  ## one connection to the bridge: a connection to the party outside that
  ## arrives in `topic`, until either end goes, the seat is let go, or
  ## whoever answered its arrival goes
  let a = attend(at, port)
  var owner = Value()  # whoever answered, nil until someone has
  proc stop() =
    a.close
    if not socket.isClosed: socket.close
  a.sub status
  a.say(topic, bl"(arrive)")
  reading(socket, proc(v: Value) = a.say(topic, v)).addCallback stop
  sleepAsync(KnockWait).addCallback proc() =
    if owner.kind == bNil: stop()
  var began = false
  a.each msg:
    if msg.by.kind == bNil:
      matchValue msg.value:
      of "(name $_)":
        if began: break  # the connection outside went, and its seat with it
        began = true
      of "(dead $o)":
        if o == owner: break
      else: discard
    elif msg.topic == a.name:
      if owner.kind == bNil:
        matchValue msg.value:
        of "(name $_ $_ $_)": owner = msg.by
        else: discard
      if msg.by == owner:
        if msg.value == bl"(gone)": break
        try: await socket.send(msg.value.ce.toString, flags = {})
        except CatchableError: break
  stop()

proc bridge*(at: IpAddress, port: Port, topic: Value): Port =
  ## a party on [::1] at a port of its own that is the party inside
  ## `topic` at the party at `at` and `port`
  let l = newAsyncSocket(AF_INET6, buffered = false)
  l.setSockOpt(OptReuseAddr, true)
  l.bindAddr(Port(0), "::1")
  l.listen
  proc accepting() {.async.} =
    while not l.isClosed:
      let socket = await l.accept
      asyncCheck door(at, port, topic, socket)
  asyncCheck accepting()
  l.getLocalAddr[1]
