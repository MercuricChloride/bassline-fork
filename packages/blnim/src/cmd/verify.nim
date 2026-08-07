import pkg/core
import pkg/lib/obm
import pkg/lib/crypto/clave
import util

const help = """
bl verify [--drop]

Checks each (signed ...) value from stdin and emits the inner value
on success; a signature that does not hold is fatal. Values that
don't claim to be signed pass through untouched.

  --drop   let go of what does not hold instead of quitting, and say
           how much at the end. A gate facing strangers has to be able
           to decline; a pipeline you control would rather stop.
"""

proc run*(args: seq[string]) =
  var drop = false
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'}, longNoVal = @["help", "drop"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "drop":
        drop = true
      else:
        quit "unknown verify option: " & key & "\n\n" & help
    else:
      quit "verify takes no arguments\n\n" & help

  var
    held = 0
    dropped = 0
  runFilter(
    proc(v: Value): Option[Value] =
      let s = v.fromValue:
        Signed
      if s.isNone:
        some v # doesn't claim to be signed
      elif s.get.holds:
        inc held
        some s.get.value
      elif drop:
        inc dropped
        none(Value)
      else:
        quit "signature verification failed"
  )
  if drop and (held + dropped) > 0:
    stderr.writeLine "-- verified " & $held & ", dropped " & $dropped
