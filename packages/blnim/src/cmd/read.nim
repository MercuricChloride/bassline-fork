import std/os
import ../lib/read as textread
import util

const help = """
bl read [file ...]

Reads values from the bassline format text and writes their canonical bytes to stdout.

If files are provided, this will read from each file is written in order and output
the concatenated bytes to stdout.

If no files are provided this will read from text from stdin.

Malformed text is fatal.
"""

proc emit(src, name: string) =
  let vs =
    try:
      readDocument(src)
    except ReadError as e:
      quit name & ": " & e.msg
  var w = writerOn(stdout)
  for v in vs:
    w.writeValue v
  w.flush()
  stdout.flushFile()

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
        quit "unknown read option: " & key & "\n\n" & help
    else:
      paths.add key

  if paths.len == 0:
    emit(stdin.readAll, "stdin")
  else:
    for path in paths:
      if not fileExists(path):
        quit "no such file: " & path
      emit(readFile(path), path)
