## bl party: values on stdin said into a topic at the party, and what
## is said into it on stdout

import std/[net, os, posix]
import harness
from bl/parties/parties import PartyPort
from bl/parties/place import placeOf

type Mode = enum
  duplex, source, sink

proc partyAt(t: Tool, a: Args): Place =
  ## --at, else the address in BL_PARTY, else the place of `bassline`
  if a.has("at"):
    try: return parsePlace(a.get("at"))
    except ValueError as e: t.misuse e.msg
  let at = getEnv("BL_PARTY")
  let host = if at.len > 0: at else: $placeOf(sym"bassline")
  Place(kind: tcpPlace, host: host, port: PartyPort)

proc play(sock: cint, topic: Value, mode: Mode, whole: bool, take: int) =
  ## Says each value on stdin into `topic`, and writes out each value
  ## said into it, or every (said …) record heard if `whole`, until
  ## `take` have been written. --source ends once stdin has ended and
  ## all of it has gone to the party. Otherwise it ends when the party
  ## does, and the end of stdin only ends speaking, since the party lets
  ## go of a connection that stops sending.
  ##
  ## The socket doesn't block: what the party hasn't taken yet waits in
  ## `owed`, and stdin isn't read again until it has gone, while the
  ## party is heard all the while.
  var
    buf = newSeq[byte](ReadChunk)
    owed: seq[byte]
    taken = 0
    written = 0
    stdinEnded = mode == sink
    hearing = mode != source
    fromStdin = newDecoder(maxValueBytes = LocalMaxValueBytes)
    fromParty = newDecoder()
  if mode != source: owed.add bl"(sub $topic)".ce
  discard fcntl(sock, F_SETFL, fcntl(sock, F_GETFL) or O_NONBLOCK)
  while hearing or not stdinEnded or owed.len > 0:
    var canRead, canWrite: TFdSet
    FD_ZERO(canRead)
    FD_ZERO(canWrite)
    if not stdinEnded and owed.len == 0: FD_SET(cint(0), canRead)
    if owed.len > 0: FD_SET(sock, canWrite)
    FD_SET(sock, canRead)
    if select(sock + 1, addr canRead, addr canWrite, nil, nil) < 0:
      if errno == EINTR: continue
      fail "select failed: " & $strerror(errno)
    if owed.len > 0 and FD_ISSET(sock, canWrite) != 0:
      let n = posix.write(sock, addr owed[taken], owed.len - taken)
      if n >= 0:
        taken += n
        if taken == owed.len:
          owed.setLen 0
          taken = 0
      elif errno notin [EINTR, EAGAIN, EWOULDBLOCK]:
        fail "can't say into the party: " & $strerror(errno)
    if not stdinEnded and owed.len == 0 and FD_ISSET(cint(0), canRead) != 0:
      let n = stdinSource().readSome(addr buf[0], buf.len)
      if n == 0:
        stdinEnded = true
        if fromStdin.pending: fail "stdin ended inside a value"
      else:
        fromStdin.buf.add buf.toOpenArray(0, n - 1)
        try:
          for view in fromStdin.checked:
            let v = view.toValue
            owed.add bl"(say $topic $v)".ce
        except CodecError as e:
          fail "stdin isn't CE: " & e.msg
        fromStdin.compact
    if FD_ISSET(sock, canRead) != 0:
      let n = posix.read(sock, addr buf[0], buf.len)
      if n == 0 or (n < 0 and errno == ECONNRESET):
        if hearing: return
        fail "the party went before everything was said"
      if n < 0:
        if errno notin [EINTR, EAGAIN, EWOULDBLOCK]:
          fail "can't hear the party: " & $strerror(errno)
        continue
      fromParty.buf.add buf.toOpenArray(0, n - 1)
      for view in fromParty.checked:
        if not hearing: continue
        let v = view.toValue
        matchValue v:
        of "(said $_ $t $x $_)":
          if whole: emit v
          elif t == topic: emit x
          else: continue
          inc written
          if written == take: return
        else: discard
      fromParty.compact

proc run(t: Tool, a: Args) =
  if a.positional.len != 1:
    t.misuse "takes exactly one topic"
  if a.has("source") and a.has("sink"):
    t.misuse "--source and --sink each leave out a half; give one at most"
  let
    mode = if a.has("source"): source elif a.has("sink"): sink else: duplex
    topic = valueArg(a.positional[0])
    take = t.intOpt(a, "count", -1, lo = 1)
    place = partyAt(t, a)
  if place.kind != tcpPlace:
    t.misuse "a party is reached over TCP. For another machine's, run bl party there: ssh HOST bl party …"
  let socket =
    try: dial(place.host, place.port, buffered = false)
    except CatchableError as e: fail "can't reach the party at " & $place & ": " & e.msg
  play(cint(socket.getFd), topic, mode, a.has("said"), take)

let tool* = Tool(
  name: "party",
  args: "TOPIC",
  summary: "stdin into a topic at the party, what is said there out",
  about: """
TOPIC is a value, written in the textual syntax or a file holding one.
Each value on stdin is said into it, and each value said into it by
anyone else comes out on stdout, as CE. With --said each (said N T V S)
record the party tells comes out whole instead, what is said into this
connection's own name among them.

The party is at the place of `bassline` on port 8455, or at the address
in BL_PARTY, or at --at PLACE. A name (`bl name` gives some) is the
place it names, and a name nothing names is the place of that name, so
`--at bassline` is the party here.

Without --source, bl party ends when the party does, or after --count
values. The end of stdin ends only its speaking, since the party lets go
of a connection that stops sending. With --source it ends once stdin
has and everything on it has gone to the party.""",
  opts: @[
    Opt(long: "source", help: "only speak: stdin into the topic"),
    Opt(long: "sink", help: "only hear: what is said into the topic to stdout"),
    Opt(long: "said", help: "write each (said …) record heard whole"),
    Opt(long: "count", short: 'n', arg: "N", help: "stop after N values"),
    Opt(long: "at", arg: "PLACE", help: "the party at PLACE")],
  run: run)
