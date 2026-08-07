import ./util
import pkg/lib/obm
import pkg/lib/stores/filestore

const help = """
bl put [--store:PATH]

Stores values from stdin in the monotonic content-addressed store 
and emits its name: (digest sha256 0x…). The receipt is the
value's "address", and thus `bl get` resolves it back.

The default store lives at ~/.bl/store.
"""

proc run*(args: seq[string]) =
  var fs = fileStore()
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'}, longNoVal = @["help"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "store":
        if val == "":
          quit "--store needs a path"
        fs.root = val
      else:
        quit "unknown put option: " & key & "\n\n" & help
    else:
      quit "put takes no arguments\n\n" & help

  runFilter(
    proc(v: Value): Option[Value] =
      some toValue fs.put(v)
  )
