import ../blnim/misc/print
import store
import util

const help = """
bl get [--store:PATH]

Resolves names to content: each (digest <algo> #[...]) value on stdin
is looked up in the store and its content value emitted. Values that
aren't digests pass through untouched, so a mixed stream resolves in
place. A name the store doesn't hold is fatal.
"""

proc run*(args: seq[string]) =
  var root = defaultStoreRoot()
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'},
                                longNoVal = @["help"]):
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
        quit "unknown get option: " & key & "\n\n" & help
    else:
      quit "get takes no arguments\n\n" & help

  let s = openStore(root)
  runFilter(
    proc (v: Value): Option[Value] =
      let d = fromValue(v, Digest)
      if d.isNone:
        return some v
      let raw =
        try:
          s.load(d.get)
        except StoreError as e:
          quit e.msg

      if raw.isNone:
        quit "not in store: " & $v

      some decode raw.get
  )
