import std/[os, parseopt, posix, strutils, times]
import bassline, bassline_crypto, bassline_jam

const usage = """
jam_serve [PLACE] [--as NAME] [--key PATH] [--keep PATH]

Serves a jam at PLACE, HOST:PORT (default 0.0.0.0:8456), taking only signed
values whose signatures hold. (Q A) puts A as an answer to Q, (Q) asks Q,
and the jam tells each line asking Q the record (Q R A) for every answer,
what it has and then each as it comes, R the order it heard it in.

--as NAME      the name it goes by (default jam)
--key PATH     sign what the jam says itself with the keypair kept in PATH.
               Without it, a key is drawn for this run
--keep PATH    begin again on the jam kept in PATH, and keep it there, every
               few seconds once it has grown, and on stopping. Without it,
               nothing is kept past this run
"""

proc fail(why: string) {.noreturn.} =
  stderr.writeLine "jam_serve: " & why
  quit 1

var stopping: bool

proc save(jam: Jam, keep: string) {.gcsafe.} =
  # written beside it and moved over it, so a stop partway through leaves the
  # jam as it was last kept
  var ce: string
  jam.reified.write(ce)
  writeFile(keep & ".new", ce)
  moveFile(keep & ".new", keep)

proc stop(sig: cint) {.noconv.} =
  stopping = true

proc main() =
  var
    place = "0.0.0.0:8456"
    name = "jam"
    keyPath, keep = ""
  for kind, key, val in getopt(shortNoVal = {'h'}, longNoVal = @["help"]):
    case kind
    of cmdArgument:
      place = key
    of cmdLongOption, cmdShortOption:
      case key
      of "as": name = val
      of "key": keyPath = val
      of "keep": keep = val
      of "h", "help":
        stdout.write usage
        quit 0
      else: fail "no option " & key & "\n" & usage
    of cmdEnd:
      discard
  let at = place.rfind(':')
  if at < 0:
    fail "a place is HOST:PORT, not " & place
  let
    host = if at == 0: "0.0.0.0" else: place[0 ..< at]
    port =
      try: Port(parseInt(place[at + 1 .. ^1]))
      except ValueError: fail "a place is HOST:PORT, not " & place
  let key =
    if keyPath.len > 0:
      let kp =
        try:
          var r = initReader()
          r.readOne(readFile(keyPath)).toNode.toKeypair
        except CatchableError as e: fail "no keypair in " & keyPath & ": " & e.msg
      if kp.scheme != EddsaBlake2b:
        fail "the jam's clients read only eddsa-blake2b, and " & keyPath & " is " & kp.scheme
      kp
    else:
      # the jam's own clients read eddsa-blake2b alone
      newKeypair(EddsaBlake2b)
  let jam =
    try:
      if keep.len > 0 and fileExists(keep):
        var r = initReader()
        var kept = r.readOne(readFile(keep)).toNode
        kept.bindJam(key)
        Jam(kept.asLive)
      else:
        newJam(Sym(name), key)
    except CatchableError as e: fail "can't begin the jam kept in " & keep & ": " & e.msg
  if keep.len > 0:
    try: jam.save(keep)
    except CatchableError as e: fail "can't keep the jam in " & keep & ": " & e.msg
    var (saved, savedAt) = (jam.len, epochTime())
    signal(SIGINT, stop)
    signal(SIGTERM, stop)
    addTimer(200, false, proc(fd: AsyncFD): bool {.gcsafe.} =
      if stopping or (jam.len != saved and epochTime() - savedAt >= 5):
        try:
          jam.save(keep)
          (saved, savedAt) = (jam.len, epochTime())
        except CatchableError as e:
          stderr.writeLine "can't keep the jam in " & keep & ": " & e.msg
      if stopping:
        quit 0)
  let listener =
    try: newListener(host, port)
    except CatchableError as e: fail "can't listen on " & place & ": " & e.msg
  listener.up(Printer(to: stderr), Lines(jam: jam))
  stderr.writeLine "listening on " & host & ":" & $listener.port.int & ", as " & name &
    (if keep.len > 0: ", keeping it in " & keep else: ", keeping nothing past this run")
  waitFor listener.serve

main()
