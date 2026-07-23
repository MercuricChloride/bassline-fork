import ../blnim/misc/clave
import util

const help = """
bl verify

Checks each (signed ...) value from stdin and emits the inner value
on success; a signature that does not hold is fatal. Values that
don't claim to be signed pass through untouched.
"""

proc run*(args: seq[string]) =
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'}, longNoVal = @["help"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      else:
        quit "unknown verify option: " & key & "\n\n" & help
    else:
      quit "verify takes no arguments\n\n" & help

  runFilter(
    proc(v: Value): Option[Value] =
      let s = v.fromValue:
        Signed
      if s.isNone:
        some v # doesn't claim to be signed
      elif s.get.holds:
        some s.get.value
      else:
        quit "signature verification failed"
  )
