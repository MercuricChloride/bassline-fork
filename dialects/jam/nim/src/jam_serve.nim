import std/[parseopt, posix, strutils]
import bassline, bassline_crypto, bassline_jam

const usage = """
jam_serve [PLACE] [--as NAME] [--log PATH] [--key PATH]

Serves a jam at PLACE, HOST:PORT (default 0.0.0.0:8456), taking only signed
values whose signatures hold. (Q A) puts A as an answer to Q, (Q) asks Q,
and the jam tells each line asking Q the record (Q R A) for every answer,
what it has and then each as it comes, R the order it heard it in.

--as NAME      the name it goes by (default jam)
--log PATH     keep what is put in PATH, and hold what PATH holds already.
               Without it, nothing is kept past this run
--key PATH     sign what the jam says itself with the keypair kept in PATH.
               Without it, a key is drawn for this run
"""

proc fail(why: string) {.noreturn.} =
  stderr.writeLine "jam_serve: " & why
  quit 1

var
  LOCK_EX {.importc, header: "<sys/file.h>".}: cint
  LOCK_NB {.importc, header: "<sys/file.h>".}: cint

proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}

proc hold(path: string) =
  # the lock lasts as long as this process, and is the one bl jam serve takes
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_APPEND,
                      S_IRUSR or S_IWUSR or S_IRGRP or S_IROTH)
  if fd < 0:
    fail "can't keep the jam in " & path & ": " & $strerror(errno)
  if flock(fd, LOCK_EX or LOCK_NB) != 0:
    let err = errno
    discard posix.close(fd)
    if err == EWOULDBLOCK:
      fail "the jam kept in " & path & " is being served already"
    fail "can't lock " & path & ": " & $strerror(err)

proc main() =
  var
    place = "0.0.0.0:8456"
    name = "jam"
    log, keyPath = ""
  for kind, key, val in getopt(shortNoVal = {'h'}, longNoVal = @["help"]):
    case kind
    of cmdArgument:
      place = key
    of cmdLongOption, cmdShortOption:
      case key
      of "as": name = val
      of "log": log = val
      of "key": keyPath = val
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
  if log.len > 0:
    hold(log)
  let jam =
    try: newJam(Sym(name), key, log)
    except CatchableError as e: fail e.msg
  let listener =
    try: newListener(host, port)
    except CatchableError as e: fail "can't listen on " & place & ": " & e.msg
  listener.up(Printer(to: stderr), Lines(jam: jam))
  stderr.writeLine "listening on " & host & ":" & $listener.port.int & ", as " & name &
    (if log.len > 0: ", keeping what is put in " & log else: ", keeping nothing past this run")
  waitFor listener.serve

main()
