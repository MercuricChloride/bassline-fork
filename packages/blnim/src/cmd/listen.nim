from std/strutils import parseInt
import pkg/core
import pkg/lib/server
import util

const help = """
bl listen [PLACE] [--echo] [--all] [--max-value:BYTES]

Lands values and writes them to stdout to be piped into
filters; bl listen | bl cat prints them.

PLACE is a local reach: unix:/path or an absolute path binds a
unix socket; port, :port, or host:port binds TCP. The default is
127.0.0.1:8455.

The landing's law is small and explicit:
  --echo             speak each landed value back to its speaker
  --all              speak each landed value to every other
                     present connection
Together they make the full clear law. With neither, the landing
only taps to stdout.

Options:
  --max-value:BYTES  refuse values bigger than this (default 150 MiB)
"""

proc run*(args: seq[string]) =
  var
    target = ""
    echoBack = false
    toAll = false
    maxValue = DefaultMaxValueBytes
  for kind, key, val in
      cmdOpts(args, shortNoVal = {'h'}, longNoVal = @["echo", "all", "help"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "echo":
        if val != "":
          quit "--echo takes no value, got: " & val
        echoBack = true
      of "all":
        if val != "":
          quit "--all takes no value, got: " & val
        toAll = true
      of "max-value":
        try:
          maxValue = parseInt(val)
        except ValueError:
          quit "--max-value needs a number of bytes, got: " & val
        if maxValue <= 0:
          quit "--max-value must be positive"
      else:
        quit "unknown listen option: " & key & "\n\n" & help
    else:
      if target != "":
        quit "listen takes one dest\n\n" & help
      target = key

  var conns: seq[Conn]

  proc onValue(conn: Conn, value: Value) {.async.} =
    emit(value)
    if toAll:
      for c in conns:
        if c != conn and not c.isClosed:
          try:
            await c.send(value)
          except CatchableError:
            discard # its close will be noticed by its own reader
    if echoBack:
      await conn.send(value)

  proc onOpen(conn: Conn) =
    conns.add conn
    stderr.writeLine "-- open " & conn.address

  proc onClose(conn: Conn) =
    for i in 0 ..< conns.len:
      if conns[i] == conn:
        conns.delete(i)
        break
    stderr.writeLine "-- close " & conn.address

  proc onError(conn: Conn, e: ref Exception) =
    stderr.writeLine "-- error " & conn.address & ": " & e.msg

  let r =
    if target == "":
      Reach(kind: rkTcp, host: "127.0.0.1", port: Port(DefaultPort))
    else:
      parseReach(target)
  case r.kind
  of rkUnix:
    let l =
      try:
        landingUnix(
          r.path,
          onValue,
          onOpen = onOpen,
          onClose = onClose,
          onError = onError,
          maxValueBytes = maxValue,
        )
      except OSError as e:
        quit "can't land on " & r.path & " -- " & e.msg
    stderr.writeLine "-- landing on " & $r
    waitFor l.serve()
  of rkTcp:
    let l =
      try:
        landing(
          r.port,
          onValue,
          onOpen = onOpen,
          onClose = onClose,
          onError = onError,
          address = r.host,
          maxValueBytes = maxValue,
        )
      except OSError as e:
        quit "can't land on " & r.host & ":" & $int(r.port) & " -- " & e.msg
    stderr.writeLine "-- landing on tcp://" & r.host & ":" & $int(l.localPort)
    waitFor l.serve()
  of rkSsh:
    quit "listen lands locally; an ssh reach is for bl reach"
