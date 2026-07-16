import std/[parseopt, strutils]
import ../blnim/server/server
import ../blnim/misc/print
import util

const help = """
bl serve [--port:N] [--address:HOST] [--echo] [--max-value:BYTES]

Lands values from TCP connections and prints each one.

Options:
  --port:N           port to land on (default 7654; 0 picks a free port)
  --address:HOST     interface to bind (default 127.0.0.1; 0.0.0.0 for all)
  --echo             speak each landed value back to its sender
  --max-value:BYTES  refuse values bigger than this (default 150 MiB)
"""

proc serveLoop(port: Port; address: string; echoBack: bool;
               maxValueBytes: int) =
  proc onValue(conn: Conn; value: Value) {.async.} =
    echo $value
    if echoBack:
      await conn.send(value)
  proc onOpen(conn: Conn) =
    stderr.writeLine "-- open " & conn.address
  proc onClose(conn: Conn) =
    stderr.writeLine "-- close " & conn.address
  proc onError(conn: Conn; e: ref Exception) =
    stderr.writeLine "-- error " & conn.address & ": " & e.msg

  let l =
    try:
      landing(port, onValue, onOpen = onOpen, onClose = onClose,
              onError = onError, address = address,
              maxValueBytes = maxValueBytes)
    except OSError as e:
      quit "can't land on " & address & ":" & $int(port) & " -- " & e.msg
  stderr.writeLine "-- landing on " & address & ":" & $int(l.localPort)
  waitFor l.serve()

proc run*(args: seq[string]) =
  var
    portStr = "7654"
    address = "127.0.0.1"
    echoBack = false
    maxValue = DefaultMaxValueBytes

  # non-empty longNoVal makes parseopt bind space-separated values
  # (--port 8000), not just --port:8000 / --port=8000
  var p = initOptParser(args, shortNoVal = {'h'},
                        longNoVal = @["echo", "help"])
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":
        echo help
        return
      of "port":
        portStr = p.val
      of "address":
        if p.val == "":
          quit "--address needs a host"
        address = p.val
      of "echo":
        if p.val != "":
          quit "--echo takes no value, got: " & p.val
        echoBack = true
      of "max-value":
        try:
          maxValue = parseInt(p.val)
        except ValueError:
          quit "--max-value needs a number of bytes, got: " & p.val
        if maxValue <= 0:
          quit "--max-value must be positive"
      else:
        quit "unknown serve option: " & p.key & "\n\n" & help
    of cmdArgument:
      quit "unexpected argument: " & p.key & "\n\n" & help

  serveLoop(parsePort(portStr, allowZero = true), address, echoBack, maxValue)
