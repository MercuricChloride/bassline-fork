import ./[store, util]

const help = """
bl put [--store:PATH]

Stores values from stdin in the monotonic content-addressed store 
and emits its name: (digest sha256 #[...]). The receipt is the
value's "address", and thus `bl get` resolves it back.

The default store lives at ~/.bl/store.
"""

proc run*(args: seq[string]) =
  var root = defaultStoreRoot()
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
        root = val
      else:
        quit "unknown put option: " & key & "\n\n" & help
    else:
      quit "put takes no arguments\n\n" & help

  let s = openStore(root)
  runFilter(
    proc(v: Value): Option[Digest] =
      some s.put(v)
  )
