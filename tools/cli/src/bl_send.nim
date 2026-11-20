## bl send: values on stdin to a place, each as it arrives

import std/[posix, sugar]
import harness
import bl/lib/server

type Outward = object
  ## where the values go: each value's CE, a flush after each read, and
  ## an end
  speak: (openArray[byte]) -> bool
  flush: () -> void
  finish: () -> void

proc overSocket(place: Place): Outward =
  ## a TCP connection by way of blnim's dialer
  var failure: ref Exception
  proc observe(e: EdgeEvent) =
    if e.kind == edgeFailed and failure == nil:
      failure = e.error
  let conn =
    try: waitFor connect(place.host, place.port, observe)
    except CatchableError as e:
      fail "can't reach " & $place & ": " & e.msg
  proc flush() =
    waitFor conn.flush()
    if failure != nil:
      fail "can't send to " & $place & ": " & failure.msg
  Outward(
    speak: (ce: openArray[byte]) => conn.write(ce),
    flush: flush,
    finish: () => (block:
      flush()
      conn.close()))

proc overSsh(place: Place): Outward =
  ## `ssh HOST bl reach --source PLACE`, the values on its stdin
  var ends: array[2, cint]
  if pipe(ends) != 0:
    fail "can't make a pipe: " & $strerror(errno)
  let argv = sshArgv(place, @["--source"])
  let pid = spawn(argv, stdinFd = ends[0], closing = ends)
  discard posix.close(ends[0])
  let into = ends[1]
  Outward(
    speak: (ce: openArray[byte]) => writeAll(into, ce),
    flush: () => (block: discard),
    finish: () => (block:
      discard posix.close(into)
      let status = waitExit(pid)
      if status != 0:
        fail "ssh to " & $place & " ended with status " & $status))

proc run(t: Tool, a: Args) =
  if a.positional.len > 1:
    t.misuse "takes one place at most"
  let spelled = if a.positional.len == 1: a.positional[0] else: configured("send", DefaultPlace)
  let place =
    try: parsePlace(spelled)
    except ValueError as e: t.misuse e.msg
  var
    outward: Outward
    count = 0
  # the place is reached when the first value is ready, so empty input
  # is silence whether or not anything is there
  proc speak(v: ValueView) =
    if count == 0:
      outward = if place.kind == sshPlace: overSsh(place)
                else: overSocket(place)
    if not outward.speak(v.ce):
      outward.flush() # fails with the reason, when there is one
      fail "can't send to " & $place & ": it stopped taking values"
    inc count
  proc flush() =
    if count > 0:
      outward.flush()
  stdinSource().eachView(speak, flush)
  if count > 0:
    outward.finish()
    chatter "sent " & $count & " value(s) to " & $place

let tool* = Tool(
  name: "send",
  args: "[PLACE]",
  summary: "values on stdin to a place, each as it arrives",
  about: """
PLACE is tcp://host:port, host:port, :port or a bare port (host
127.0.0.1), or ssh://host/PLACE to run `bl reach --source PLACE` there,
PLACE being a TCP place on the far side (ssh://host alone reaches the
far side's """ & DefaultPlace & """). The default is the config's send
(`bl config send PLACE`), else """ & DefaultPlace & """, where `bl serve`
listens by default. A name from `bl name` is the place it names.

The place is reached when the first value arrives, and the values go
as CE, byte for byte as they came. Empty input sends nothing and says
nothing.""",
  run: run)
