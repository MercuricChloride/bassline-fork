import std/[parseopt, strutils]
import ../blnim/server/server
import util

const help = """
bl send <dest>

Reads values (binary encoding) from stdin and speaks each one to
dest, then closes. dest is host:port, :port, or a bare port; host
defaults to 127.0.0.1.
"""

proc parseDest(dest: string): (string, Port) =
  var
    host = "127.0.0.1"
    portStr = dest
  let i = dest.rfind(':')
  if i >= 0:
    if i > 0:
      host = dest[0 ..< i]
    portStr = dest[i + 1 .. ^1]
  if portStr == "" or not portStr.allCharsInSet({'0' .. '9'}):
    quit "dest needs a port, got: " & dest
  (host, parsePort(portStr))

proc run*(args: seq[string]) =
  var dest = ""
  var p = initOptParser(args)
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":
        echo help
        return
      else:
        quit "unknown send option: " & p.key & "\n\n" & help
    of cmdArgument:
      if dest != "":
        quit "send takes exactly one dest\n\n" & help
      dest = p.key

  if dest == "":
    quit "send needs a dest\n\n" & help
  let (host, port) = parseDest(dest)

  let input = stdin.readAll()
  if input.len == 0:
    quit "nothing on stdin"

  # validate that stdin reads valid values
  # We don't have a size cap here, since anything other the
  # allowed limits will get caught in the decoder or get
  # rejected by the consumer
  var sd = initStreamDecoder(maxValueBytes = high(int) div 2)
  var values: seq[Value]
  try:
    sd.feed(input.toOpenArrayByte(0, input.high))
    while true:
      let v = sd.next()
      if v.isNone:
        break
      values.add v.get
  except DecodeError as e:
    quit "stdin isn't a value stream: " & e.msg
  if sd.buffered > 0:
    quit "stdin ends mid-value (" & $sd.buffered & " incomplete bytes)"

  proc go() {.async.} =
    let conn = await connect(host, port)
    for v in values:
      await conn.send(v)
    conn.close()
  waitFor go()
  stderr.writeLine "-- sent " & $values.len & " value(s) to " & host & ":" & $int(port)
