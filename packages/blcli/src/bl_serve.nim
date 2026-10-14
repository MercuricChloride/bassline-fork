## bl serve: a listener whose values go to stdout as they arrive

import std/sugar
import harness
import bl/lib/server

proc run(t: Tool, a: Args) =
  if a.positional.len > 1:
    t.misuse "takes one place at most"
  let spelled = if a.positional.len == 1: a.positional[0] else: DefaultPlace
  let place =
    try: parsePlace(spelled, allowZero = true)
    except ValueError as e: t.misuse e.msg
  if place.kind == sshPlace:
    t.misuse "a listener is local; ssh:// is for send and reach"
  let maxValue = t.intOpt(a, "max-value", MaxValueBytes, lo = 1)
  if maxValue > MaxValueBytes:
    t.misuse "--max-value can't pass the listener's own cap of " &
      $MaxValueBytes & " bytes"

  let observe: Observer = (e: EdgeEvent) => chatter($e)
  proc relay(ce: openArray[byte]): bool =
    # raising ends that connection's reading, told to the observer
    if ce.len > maxValue:
      raise newException(ValueError, "a value of " & $ce.len &
                         " bytes is past --max-value " & $maxValue)
    emit ce
    true

  var listener: Listener
  try:
    listener = newListener(place.port, relay, observe, place.host)
    chatter "listening on " & $Place(kind: tcpPlace, host: place.host,
                                     port: listener.port)
  except CatchableError as e:
    fail "can't listen on " & $place & ": " & e.msg
  waitFor listener.serve()

let tool* = Tool(
  name: "serve",
  args: "[PLACE]",
  summary: "a listener: every value that arrives goes straight to stdout as CE",
  about: """
PLACE is tcp://host:port, host:port, :port or a bare port (host
127.0.0.1; port 0 takes whatever is free). The default is
""" & DefaultPlace & """, where `bl send` speaks by default.

Each value goes out byte for byte as it arrived, never re-encoded.
Nothing is spoken back down a connection. What happens at the edge goes
to stderr, one line each: open, close, truncated (the other end stopped
partway through a value), malformed (not CE, or past the listener's own
cap), failed (the socket failed, or a value was past --max-value). A
connection that sends something wrong is dropped; the listener carries
on.""",
  opts: @[Opt(long: "max-value", arg: "BYTES",
              help: "drop a connection that sends a value bigger than this " &
                    "(at most, and by default, " & $MaxValueBytes & ")")],
  run: run)
