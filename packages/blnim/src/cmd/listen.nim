import std/os
from std/strutils import parseInt
import ../blnim/server/server
import util

const help = """
bl listen [on] [--echo] [--max-value:BYTES]

Lands values and writes them to stdout to be piped into
filters; bl listen | bl cat prints them. 

`on` is either a TCP dest (port, :port, or host:port -- default 127.0.0.1:8455) or a file
path, which is followed: existing values are emitted, then appends
as they land. A file that spells like a port should have a ./ prefix.

Options:
  --echo             TCP only: speak each landed value back
  --max-value:BYTES  refuse values bigger than this (default 150 MiB)
"""

proc emit(v: Value) =
  let ce = encode(v)
  if stdout.writeBuffer(addr ce[0], ce.len) != ce.len:
    quit "short write to stdout"
  stdout.flushFile()  # so downstream sees each value promptly

proc listenTcp(host: string; port: Port; echoBack: bool; maxValue: int) =
  proc onValue(conn: Conn; value: Value) {.async.} =
    emit(value)
    if echoBack:
      await conn.send(value)
  proc onOpen(conn: Conn) =
    stderr.writeLine "-- open " & conn.address
  proc onClose(conn: Conn) =
    stderr.writeLine "-- close " & conn.address
  proc onError(conn: Conn; e: ref Exception) =
    stderr.writeLine "-- error " & conn.address & ": " & e.msg

  let l =
    try:
      landing(port, onValue, onOpen = onOpen, onClose = onClose,
              onError = onError, address = host, maxValueBytes = maxValue)
    except OSError as e:
      quit "can't land on " & host & ":" & $int(port) & " -- " & e.msg
  stderr.writeLine "-- landing on " & host & ":" & $int(l.localPort)
  waitFor l.serve()

proc listenFile(path: string; maxValue: int) =
  ## A file is a landing surface too: anyone appending to it is
  ## sending. Emits what's there, then follows.
  if not fileExists(path):
    writeFile(path, "")
  var f: File
  if not open(f, path):
    quit "can't open: " & path
  stderr.writeLine "-- landing on " & path
  var
    sd = initStreamDecoder(maxValueBytes = maxValue)
    buf = newSeq[byte](16 * 1024)
  while true:
    let n = f.readBuffer(addr buf[0], buf.len)
    if n > 0:
      sd.feed(buf.toOpenArray(0, n - 1))
      while true:
        let v =
          try:
            sd.next()
          except DecodeError as e:
            quit path & " isn't a value stream: " & e.msg
        if v.isNone:
          break
        emit(v.get)
    else:
      sleep(100)
      f.setFilePos(f.getFilePos())  # fseek clears stdio's EOF latch

proc run*(args: seq[string]) =
  var
    target = ""
    echoBack = false
    maxValue = DefaultMaxValueBytes
  for kind, key, val in cmdOpts(args, shortNoVal = {'h'},
                                longNoVal = @["echo", "help"]):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "echo":
        if val != "":
          quit "--echo takes no value, got: " & val
        echoBack = true
      of "max-value":
        try:
          maxValue = parseInt(val)
        except ValueError:
          quit "--max-value needs a number of bytes, got: " & val
        if maxValue <= 0:
          quit "--max-value must be positive"
      else:
        quit "unknown listen option: " & key & "\n\n" & help
    else:
      if target != "":
        quit "listen takes one target\n\n" & help
      target = key

  if target == "":
    listenTcp("127.0.0.1", Port(DefaultPort), echoBack, maxValue)
  elif isDestSpelling(target):
    let (host, port) = parseDest(target)
    listenTcp(host, port, echoBack, maxValue)
  else:
    listenFile(target, maxValue)
