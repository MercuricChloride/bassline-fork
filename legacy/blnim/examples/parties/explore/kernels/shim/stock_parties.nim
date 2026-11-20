##[
  Where programs on one machine meet: a daemon served at the place of a
  value, `bassline` unless given another, on port 8455.

  A connection is first told (name N S P), S the value it goes by and P
  the value the party goes by. It hears S from then on, and every topic
  it says (sub T) for, until it says (unsub T). It says (say T V) to say
  V into the topic T, and everyone else who hears T is told
  (said N T V S), S what the speaker goes by. A topic is any value,
  heard by whoever said that very value.

  A connection may own topics, by saying (own {T …}) first, before
  anything else. What others say into a topic it owns goes to it alone,
  and what it says there goes to everyone who hears the topic. It owns
  them until it goes. A topic someone owns already can't be owned again,
  and a connection that asks for one is told so and let go.

  The daemon says things too, by nil. It owns the topic `status`, and
  says (alive S) into it when a connection arrives and (dead S) when it
  goes. A connection that begins to hear `status` is told (alive S) for
  everyone else already here. Anything else a connection says, a say into
  `status` among it, the daemon says back into what it goes by as
  (invalid X).

  N orders everything the daemon says. It is one count for the whole
  daemon, so everyone told of one value is told the same N. P tells one
  daemon's order from another's.

  What a connection hears ends with it. The value it went by is sixteen
  random bytes, so it is never given out again. A connection has gone
  once it stops sending, once a write to it fails, or once it leaves
  more than `MaxUnsent` bytes unread.

  The daemon is a bag of state and an async loop for each connection,
  and a program attending it (`attend`) is an async loop of its own,
  connecting again whenever its connection goes.
]##
import std/[asyncdispatch, asyncnet, deques, net, options, sysrand, tables, times]
import bl/core
import bl/parties/place

export asyncdispatch, asyncnet, net, options, place

const
  PartyPort* = Port(8455)
  MaxUnsent* {.intdefine.} = 16 * 1024 * 1024
    ## the most bytes a connection may leave unread before it has gone

blet"{bassline}"

# ================
# Values over a socket
# ================

const Chunk = 16 * 1024

type Reader = ref object
  socket: AsyncSocket
  decoder: Decoder
  kept: Deque[Value]

proc reader(socket: AsyncSocket): Reader =
  Reader(socket: socket, decoder: newDecoder())

proc read(r: Reader): Future[Option[Value]] {.async.} =
  ## the next value off the socket, none once it has ended or sent bytes
  ## that are not CE
  while r.kept.len == 0:
    if r.socket.isClosed: return none(Value)
    try:
      let data = await r.socket.recv(Chunk, flags = {})
      if data.len == 0: return none(Value)
      r.decoder.buf.add data.toBytes
      for view in r.decoder.checked:
        r.kept.addLast view.toValue
      r.decoder.compact
    except CatchableError:
      return none(Value)
  return some r.kept.popFirst

proc domainOf(at: IpAddress): Domain =
  if at.family == IPv6: AF_INET6 else: AF_INET

# ================
# The daemon
# ================

type
  Seat = ref object
    socket: AsyncSocket
    name: Value
    hears: seq[Value]
    owns: seq[Value]
    spoke: bool  ## whether it has said anything yet
    unsent: int  ## bytes written to it that haven't gone out yet
    writing: Future[void]  ## the last write
    going: bool  ## to leave once the party has said what it is saying
    gone: bool

  Party* = ref object
    listener: AsyncSocket
    name*: Value                       ## what it goes by, sixteen random bytes
    said: int                          ## how many things it has said
    seats: seq[Seat]
    hearers: Table[string, seq[Seat]]  ## who hears each topic, by its CE
    owners: Table[string, Seat]        ## who owns each topic owned, nil for the party
    going: seq[Seat]                   ## to leave once it has said what it is saying

proc next(p: Party): int =
  inc p.said
  p.said

proc unhear(p: Party, s: Seat, t: Value) =
  let i = s.hears.find t
  if i < 0: return
  s.hears.del i
  let k = t.ce.toString
  p.hearers[k].del p.hearers[k].find(s)
  if p.hearers[k].len == 0: p.hearers.del k

proc leave(p: Party, s: Seat) {.gcsafe.}

proc tell(p: Party, s: Seat, v: Value) =
  ## writes `v` to `s`. One that leaves too much unread goes once the
  ## party has said what it is saying, so everyone hears its going after
  ## that, and one whose write fails goes then
  if s.gone or s.going: return
  let bytes = v.ce.toString
  s.unsent += bytes.len
  if s.unsent > MaxUnsent:
    s.going = true
    p.going.add s
    return
  s.writing = s.socket.send(bytes, flags = {})
  s.writing.addCallback(
    proc(f: Future[void]) =
      s.unsent -= bytes.len
      if f.failed: p.leave s)

proc sayTo(p: Party, hearers: seq[Seat], t, v, by: Value, but: Seat = nil) =
  ## says `v` into `t` as `by`, to `hearers` but `but`
  let n = p.next
  for h in hearers:
    if h != but: p.tell(h, bl"(said $n $t $v $by)")
  while p.going.len > 0: p.leave p.going.pop

proc say(p: Party, t, v, by: Value, but: Seat = nil) =
  ## says `v` into `t` as `by`, to everyone who hears `t` but `but`
  p.sayTo(p.hearers.getOrDefault(t.ce.toString), t, v, by, but)

proc hear(p: Party, s: Seat, t: Value) =
  if t in s.hears: return
  s.hears.add t
  p.hearers.mgetOrPut(t.ce.toString, @[]).add s
  if t == bl"status":
    for o in p.seats:
      let name = o.name
      if o != s: p.sayTo(@[s], t, bl"(alive $name)", Value())

proc leave(p: Party, s: Seat) {.gcsafe.} =
  if s.gone: return
  s.gone = true
  let (hears, name) = (s.hears, s.name)
  for t in hears: p.unhear(s, t)
  for t in s.owns: p.owners.del t.ce.toString
  p.seats.del p.seats.find(s)
  if s.going or s.writing.isNil or s.writing.finished: s.socket.close
  else: s.writing.addCallback proc() = s.socket.close  # what it was told goes out first
  p.say(bl"status", bl"(dead $name)", Value())

proc own(p: Party, s: Seat, said, topics: Value) =
  ## `s` owns `topics`, unless it has spoken already or one is owned
  if s.spoke or topics.kind != bSet:
    p.say(s.name, bl"(invalid $said)", Value())
    return
  for t in topics.els:
    if p.owners.hasKey(t.ce.toString):
      p.say(s.name, bl"(invalid $said)", Value())
      p.leave s
      return
  for t in topics.els:
    p.owners[t.ce.toString] = s
    s.owns.add t

proc sayFrom(p: Party, s: Seat, said, t, v: Value) =
  ## what `s` says into `t`: to its owner alone if someone else owns it
  let k = t.ce.toString
  if not p.owners.hasKey(k) or p.owners[k] == s: p.say(t, v, s.name, but = s)
  elif p.owners[k].isNil: p.say(s.name, bl"(invalid $said)", Value())
  else: p.sayTo(@[p.owners[k]], t, v, s.name)

proc seat(p: Party, socket: AsyncSocket) {.async.} =
  let
    s = Seat(socket: socket, name: bytes(urandom 16))
    r = reader(socket)
    (n, name, party) = (p.next, s.name, p.name)
  p.seats.add s
  p.tell(s, bl"(name $n $name $party)")
  p.hear(s, name)
  p.say(bl"status", bl"(alive $name)", Value(), but = s)
  while not s.gone:
    let v = await r.read
    if v.isNone: break
    let said = v.get
    matchValue said:
    of "(own $topics)": p.own(s, said, topics)
    of "(sub $t)": p.hear(s, t)
    of "(unsub $t)": p.unhear(s, t)
    of "(say $t $x)": p.sayFrom(s, said, t, x)
    else: p.say(name, bl"(invalid $said)", Value())
    s.spoke = true
  p.leave s

proc accepting(p: Party) {.async.} =
  while not p.listener.isClosed:
    var socket: AsyncSocket
    try:
      socket = await p.listener.accept
    except CatchableError:
      if p.listener.isClosed: break
      await sleepAsync(100)  # so a lasting failure doesn't spin
      continue
    asyncCheck p.seat(socket)

proc serve*(at = placeOf(bassline), port = PartyPort): Party =
  ## a party listening at `at` and `port`. Sockets are unbuffered, since
  ## a buffered recv waits to fill the whole chunk
  let l = newAsyncSocket(at.domainOf, buffered = false)
  try:
    l.setSockOpt(OptReuseAddr, true)
    l.bindAddr(port, $at)
    l.listen
  except CatchableError:
    l.close
    raise
  result = Party(listener: l, name: bytes(urandom 16))
  result.owners[bl"status".ce.toString] = nil
  asyncCheck result.accepting

proc port*(p: Party): Port =
  p.listener.getLocalAddr[1]

proc close*(p: Party) =
  ## stops accepting. Connections already seated stay
  if not p.listener.isClosed: p.listener.close

# ================
# Attending
# ================

const
  FirstWait = 100        ## ms to wait after a connection fails, doubled each time
  LongestWait = 30_000
  Lasting = 1.0          ## seconds a connection must last for the wait to begin again

type
  Said* = object
    ## a value said into a topic, as the party told it
    n*: int        ## where the party said it in its order
    topic*: Value
    by*: Value     ## what whoever said it goes by, nil for the party
    value*: Value
    party*: Value  ## what the party goes by, whose order `n` is in

  Attendee* = ref object
    ## a program at a party. It connects in the background, and again
    ## whenever its connection goes, waiting twice as long each time a try
    ## fails or a connection ends at once. Each connection owns `owns` and
    ## hears every topic it has said `sub` for, and what it says between
    ## connections waits for the next one, up to `MaxUnsent` bytes. Each
    ## connection begins with the party saying (name S) into S
    at: IpAddress
    port: Port
    owns*: seq[Value]         ## what it owns, said first on every connection
    reader: Reader            ## nil between connections
    name*: Value              ## what it goes by now, nil between connections
    party: Value              ## what the party it is connected to goes by
    ready*: Future[void]      ## complete while it has a connection, or once closed
    hears: seq[Value]
    told: Deque[Said]         ## what the party said that `next` hasn't taken
    waiting: Deque[string]    ## what it said between connections, as CE
    waitingBytes: int
    wait: int                 ## ms to wait before trying again
    since: float              ## when this connection began
    reading: bool             ## whether a `next` is waiting
    closed: bool

proc lost(a: Attendee, r: Reader)

proc put(a: Attendee, bytes: string): bool

proc write(a: Attendee, r: Reader, bytes: string, again = true) =
  ## sends `bytes` on `r`. Writes on one socket go out whole and in order.
  ## One that fails loses the connection, and its bytes are said again on
  ## the next, if `again`
  r.socket.send(bytes, flags = {}).addCallback(
    proc(f: Future[void]) =
      if f.failed:
        {.cast(gcsafe).}:  # one thread: the dispatcher's
          a.lost r
          if again: discard a.put bytes)

proc put(a: Attendee, bytes: string): bool =
  ## says `bytes` now, or keeps them for the next connection if there is
  ## room, answering whether it did either
  if not a.reader.isNil:
    a.write(a.reader, bytes)
    return true
  if a.waitingBytes + bytes.len > MaxUnsent: return false
  a.waiting.addLast bytes
  a.waitingBytes += bytes.len
  true

proc connect(a: Attendee): Future[(Reader, Value, Value, int)] {.async.} =
  ## one connection, once the party has said what it and this go by
  let socket = newAsyncSocket(a.at.domainOf, buffered = false)
  try:
    await socket.connect($a.at, a.port)
    let
      r = reader(socket)
      first = await r.read
    if first.isSome:
      matchValue first.get:
      of "(name $n $name $party)":
        if n.kind == bNum: return (r, name, party, n.num.toInt)
      else: discard
  except CatchableError:
    discard
  socket.close
  return (nil, Value(), Value(), 0)

proc connecting(a: Attendee, delay: int) {.async.} =
  if delay > 0: await sleepAsync(delay)
  while not a.closed:
    let (r, name, party, n) = await a.connect
    if r.isNil:
      await sleepAsync(a.wait)
      a.wait = min(2 * a.wait, LongestWait)
      continue
    if a.closed:
      r.socket.close
      return
    (a.name, a.party, a.since) = (name, party, epochTime())
    a.reader = r
    a.told.addLast Said(n: n, topic: name, by: Value(), value: bl"(name $name)", party: party)
    let owns = a.owns
    if owns.len > 0: a.write(r, bl"(own {@owns})".ce.toString, again = false)
    for t in a.hears: a.write(r, bl"(sub $t)".ce.toString, again = false)
    while a.waiting.len > 0: a.write(r, a.waiting.popFirst)
    a.waitingBytes = 0
    a.ready.complete
    return

proc lost(a: Attendee, r: Reader) =
  ## `r` has gone, so `a` connects again, unless it has already. After a
  ## connection that ended at once it waits first, longer each time
  if a.reader != r: return
  a.reader = nil
  a.name = Value()
  r.socket.close
  a.ready = newFuture[void]("ready")
  if a.closed: return
  var delay = 0
  if epochTime() - a.since < Lasting:
    delay = a.wait
    a.wait = min(2 * a.wait, LongestWait)
  else:
    a.wait = FirstWait
  asyncCheck a.connecting(delay)

proc attend*(at = placeOf(bassline), port = PartyPort, owns: seq[Value] = @[]): Attendee =
  ## a program at the party at `at` and `port`, owning `owns`, connecting
  ## once the dispatcher runs
  result = Attendee(at: at, port: port, owns: owns, ready: newFuture[void]("ready"),
                    wait: FirstWait)
  asyncCheck result.connecting(0)

proc send*(a: Attendee, v: Value): bool {.discardable.} =
  ## says `v` to the party as it is, now or on the next connection,
  ## answering whether it could
  a.put v.ce.toString

proc hears*(a: Attendee, topic: Value): bool =
  ## whether `a` hears `topic`
  topic in a.hears or (a.name.kind != bNil and topic == a.name)

proc sub*(a: Attendee, topic: Value) =
  ## hears `topic` on this connection and every one after
  if a.hears(topic): return
  a.hears.add topic
  if not a.reader.isNil: a.send bl"(sub $topic)"

proc unsub*(a: Attendee, topic: Value) =
  let i = a.hears.find topic
  if i < 0: return
  a.hears.del i
  if not a.reader.isNil: a.send bl"(unsub $topic)"

proc say*(a: Attendee, topic, v: Value): bool {.discardable.} =
  a.send bl"(say $topic $v)"

proc taking(a: Attendee): Future[Option[Said]] {.async.} =
  while not a.closed:
    if a.told.len > 0: return some a.told.popFirst
    let r = a.reader
    if r.isNil:
      await a.ready
      continue
    let v = await r.read
    if v.isNone:
      a.lost r
      continue
    matchValue v.get:
    of "(said $n $t $x $by)":
      if n.kind == bNum:
        return some Said(n: n.num.toInt, topic: t, by: by, value: x, party: a.party)
    else: discard
  return none(Said)

proc next*(a: Attendee): Future[Option[Said]] {.async.} =
  ## the next thing said that `a` hears, across connections, none once
  ## it is closed. Only one may wait at a time
  if a.reading: raise newException(ValueError, "something is reading this attendee already")
  a.reading = true
  let said = await a.taking
  a.reading = false
  return said

template each*(a: Attendee, msg, body: untyped) =
  ## takes everything `a` hears, one at a time, until it is closed
  while true:
    let next = await a.next
    if next.isNone: break
    let msg = next.get
    body

proc isClosed*(a: Attendee): bool = a.closed

proc close*(a: Attendee) =
  ## leaves the party for good
  a.closed = true
  if not a.reader.isNil: a.reader.socket.close
  a.reader = nil
  a.name = Value()
  if not a.ready.finished: a.ready.complete
