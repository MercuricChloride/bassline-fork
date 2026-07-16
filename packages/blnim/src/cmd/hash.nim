import ../blnim/codec/digest
import ../blnim/misc/common
import util

const help = """
bl hash

Reads values from stdin and writes each one's name by content:
(digest sha256 #[sha256 of its canonical bytes]).
"""

proc run*(args: seq[string]) =
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'},
                                longNoVal = @["help"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      else:
        quit "unknown hash option: " & key & "\n\n" & help
    else:
      quit "hash takes no arguments\n\n" & help

  runFilter(proc (v: Value): Option[Value] =
    some digest("sha256", sha256(v)))
