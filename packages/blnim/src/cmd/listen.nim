from std/strutils import parseInt
import ../core
import ../lib/server
import util

const help = """
bl listen [on] [--echo] [--max-value:BYTES]

Lands values and writes them to stdout to be piped into
filters; bl listen | bl cat prints them.

`on` is a TCP dest: port, :port, or host:port. The default is
127.0.0.1:8455.

Options:
  --echo             speak each landed value back
  --max-value:BYTES  refuse values bigger than this (default 150 MiB)
"""

proc run*(args: seq[string]) =
  var
    target = ""
    echoBack = false
    maxValue = DefaultMaxValueBytes
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'}, longNoVal = @["echo", "help"]):
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

  let (host, port) =
    if target == "":
      ("127.0.0.1", Port(DefaultPort))
    else:
      parseDest(target)

  proc onValue(conn: Conn, value: Value) {.async.} =
    emit(value)
    if echoBack:
      await conn.send(value)

  proc onOpen(conn: Conn) =
    stderr.writeLine "-- open " & conn.address

  proc onClose(conn: Conn) =
    stderr.writeLine "-- close " & conn.address

  proc onError(conn: Conn, e: ref Exception) =
    stderr.writeLine "-- error " & conn.address & ": " & e.msg

  let l =
    try:
      landing(
        port,
        onValue,
        onOpen = onOpen,
        onClose = onClose,
        onError = onError,
        address = host,
        maxValueBytes = maxValue,
      )
    except OSError as e:
      quit "can't land on " & host & ":" & $int(port) & " -- " & e.msg
  stderr.writeLine "-- landing on " & host & ":" & $int(l.localPort)
  waitFor l.serve()
