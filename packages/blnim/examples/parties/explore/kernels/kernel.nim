##[
  The daemon of `bl/parties/parties.nim`, the same dialect, with the
  decisions only a party can make left open as methods. The stock party
  is this with none of them changed. A kernel is a `Party` of its own
  type overriding some of them, and served with `serve`.

  - `arrived`: a connection has been told its name. A kernel may own
    topics for it, or let it go.
  - `admits`: whether a connection may `own`, `sub` or `say` into a
    topic. What it says is said back as (invalid X) if not.
  - `into`: the topic a say into T is said into.
  - `by`: what a speaker goes by in the topic it says into.
  - `record`: each value the party says in its order, once.
  - `left`: a connection has gone.

  None of them reads V. `admits` is handed a verb and a topic, `record`
  keeps what it is handed whole, and the rest see connections, topics
  by their CE, and the order.
]##
import std/[asyncdispatch, asyncnet, deques, net, options, sysrand, tables]
import bl/core

export asyncdispatch, asyncnet, net, options

const
  MaxUnsent* {.intdefine.} = 16 * 1024 * 1024
  Chunk = 16 * 1024


type Reader* = ref object
  socket: AsyncSocket
  decoder: Decoder
  kept: Deque[Value]

proc reader*(socket: AsyncSocket): Reader =
  Reader(socket: socket, decoder: newDecoder())

proc read*(r: Reader): Future[Option[Value]] {.async.} =
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

proc domainOf*(at: IpAddress): Domain =
  if at.family == IPv6: AF_INET6 else: AF_INET

type
  Seat* = ref object
    socket: AsyncSocket
    name*: Value
    hears: seq[Value]
    owns*: seq[Value]
    spoke: bool
    unsent: int
    writing: Future[void]
    going: bool
    gone*: bool

  Party* = ref object of RootObj
    listener: AsyncSocket
    name*: Value                        ## what it goes by
    said*: int                          ## how many things it has said
    seats*: seq[Seat]
    hearers: Table[string, seq[Seat]]
    owners*: Table[string, Seat]        ## nil for the party
    going: seq[Seat]

method arrived*(p: Party, s: Seat) {.base, gcsafe.} = discard
method admits*(p: Party, s: Seat, verb, t: Value): bool {.base, gcsafe.} = true
method into*(p: Party, s: Seat, t: Value): Value {.base, gcsafe.} = t
method by*(p: Party, s: Seat, t: Value): Value {.base, gcsafe.} = s.name
method record*(p: Party, v: Value) {.base, gcsafe.} = discard
method left*(p: Party, s: Seat) {.base, gcsafe.} = discard

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

proc leave*(p: Party, s: Seat) {.gcsafe.}

proc tell(p: Party, s: Seat, v: Value) =
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
  let n = p.next
  let said = bl"(said $n $t $v $by)"
  p.record said
  for h in hearers:
    if h != but: p.tell(h, said)
  while p.going.len > 0: p.leave p.going.pop

proc say(p: Party, t, v, by: Value, but: Seat = nil) =
  p.sayTo(p.hearers.getOrDefault(t.ce.toString), t, v, by, but)

proc hear(p: Party, s: Seat, t: Value) =
  if t in s.hears: return
  s.hears.add t
  p.hearers.mgetOrPut(t.ce.toString, @[]).add s
  if t == bl"status":
    for o in p.seats:
      let name = o.name
      if o != s: p.sayTo(@[s], t, bl"(alive $name)", Value())

proc leave*(p: Party, s: Seat) {.gcsafe.} =
  if s.gone: return
  s.gone = true
  let (hears, name) = (s.hears, s.name)
  for t in hears: p.unhear(s, t)
  for t in s.owns: p.owners.del t.ce.toString
  p.seats.del p.seats.find(s)
  if s.going or s.writing.isNil or s.writing.finished: s.socket.close
  else: s.writing.addCallback proc() = s.socket.close
  p.left s
  p.say(bl"status", bl"(dead $name)", Value())

proc own(p: Party, s: Seat, said, topics: Value) =
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

proc sayFrom(p: Party, s: Seat, said, topic, v: Value) =
  let
    t = p.into(s, topic)
    k = t.ce.toString
  if not p.owners.hasKey(k) or p.owners[k] == s: p.say(t, v, p.by(s, t), but = s)
  elif p.owners[k].isNil: p.say(s.name, bl"(invalid $said)", Value())
  else: p.sayTo(@[p.owners[k]], t, v, p.by(s, t))

proc admitted(p: Party, s: Seat, said: Value): bool =
  ## whether `s` may say `said`, asked of the kernel by topic alone
  matchValue said:
  of "(own $ts)":
    if ts.kind != bSet: return true
    for t in ts.els:
      if not p.admits(s, bl"own", t): return false
    true
  of "(sub $t)": p.admits(s, bl"sub", t)
  of "(say $t $_)": p.admits(s, bl"say", t)
  else: true

proc seat(p: Party, socket: AsyncSocket) {.async.} =
  let
    s = Seat(socket: socket, name: bytes(urandom 16))
    r = reader(socket)
    (n, name, party) = (p.next, s.name, p.name)
    greeting = bl"(name $n $name $party)"
  p.seats.add s
  p.record greeting
  p.tell(s, greeting)
  p.hear(s, name)
  p.arrived s
  if not s.gone: p.say(bl"status", bl"(alive $name)", Value(), but = s)
  while not s.gone:
    let v = await r.read
    if v.isNone: break
    let said = v.get
    if not p.admitted(s, said):
      p.say(name, bl"(invalid $said)", Value())
    else:
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
      await sleepAsync(100)
      continue
    asyncCheck p.seat(socket)

proc serve*[P: Party](p: P, at = parseIpAddress("::1"), port = Port(0)): P =
  ## serves `p` at `at` and `port`, going by sixteen random bytes unless
  ## it goes by something already
  let l = newAsyncSocket(at.domainOf, buffered = false)
  try:
    l.setSockOpt(OptReuseAddr, true)
    l.bindAddr(port, $at)
    l.listen
  except CatchableError:
    l.close
    raise
  p.listener = l
  if p.name.kind == bNil: p.name = bytes(urandom 16)
  p.owners[bl"status".ce.toString] = nil
  asyncCheck p.accepting
  p

proc port*(p: Party): Port =
  p.listener.getLocalAddr[1]

proc close*(p: Party) =
  if not p.listener.isClosed: p.listener.close

proc announce*(p: Party) =
  ## says where it is and what it goes by, for whoever started it
  echo "[::1]:", p.port.int, " ", p.name
  stdout.flushFile
