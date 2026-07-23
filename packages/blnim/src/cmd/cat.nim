import ../core
import ../lib/print
import util

const help = """
bl cat [file ...]

Prints values from .blb files or stdin in the bassline text format
You can read the output of this with bl read
"""

proc run*(args: seq[string]) =
  var paths: seq[string]
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'}, longNoVal = @["help"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      else:
        quit "unknown cat option: " & key & "\n\n" & help
    else:
      paths.add key

  proc show(v: Value) =
    echo $v

  if paths.len == 0:
    eachValue(stdin, show)
  else:
    for path in paths:
      var f: File
      if not open(f, path):
        quit "can't open: " & path
      eachValue(f, show)
      close(f)
