import ./util
import pkg/lib/[obmcommon, reader]
import pkg/lib/stores/filestore

const help = """
bl get [--store:PATH]

Resolves names to content: each (digest <algo> 0x…) value on stdin
is looked up in the store and its content value emitted. Values that
aren't digests pass through untouched, so a mixed stream resolves in
place. A name the store doesn't hold is fatal.
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
        quit "unknown get option: " & key & "\n\n" & help
    else:
      quit "get takes no arguments\n\n" & help

  runFilter(
    proc(v: Value): Option[Value] =
      let d = fromValue(v, Digest)
      if d.isNone:
        return some v
      let got =
        try:
          fs.get(d.get)
        except ValueError as e:
          quit "get: " & e.msg
      if got.isNone:
        quit "get: the store doesn't hold " & $v
      got
  )