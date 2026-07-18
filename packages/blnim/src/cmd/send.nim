import std/parseopt
import ../blnim/server/server
import util

const help = """
bl send [dest]

Reads values from stdin and speaks each one to
dest, then closes. dest is host:port, :port, or a bare port; host
defaults to 127.0.0.1, and no dest at all means 127.0.0.1:8455 which
is the default for bl listen.
"""

proc run*(args: seq[string]) =
  var dest = ""
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'},
                                longNoVal = @["help"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      else:
        quit "unknown send option: " & key & "\n\n" & help
    else:
      if dest != "":
        quit "send takes exactly one dest\n\n" & help
      dest = key

  let (host, port) =
    if dest == "":
      ("127.0.0.1", Port(DefaultPort))
    else:
      parseDest(dest)

  let conn =
    try:
      waitFor connect(host, port)
    except OSError as e:
      quit "can't reach " & host & ":" & $int(port) & " -- " & e.msg
  var count = 0
  eachValue(stdin, proc (v: Value) =
    waitFor conn.send(v)
    inc count)
  conn.close()
  if count == 0:
    quit "no values on stdin"
  stderr.writeLine "-- sent " & $count & " value(s) to " & host & ":" & $int(port)
