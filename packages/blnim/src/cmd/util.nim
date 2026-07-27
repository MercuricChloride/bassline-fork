import std/[strutils, nativesockets, options, parseopt, os, posix, random]
import ../core
export core, options, parseopt, random

proc blHome*(): string =
  ## Everything bl keeps locally lives under one roof.
  getHomeDir() / ".bl"

const DefaultPort* = 8455 # where bl listen lands by default

proc parsePort(s: string, allowZero = false): Port =
  ## Port(x) wraps modulo 2^16 on out-of-range ints, so the range
  ## check has to happen here.
  var port: int
  try:
    port = parseInt(s)
  except ValueError:
    quit "port must be a number, got: " & s
  let lo = if allowZero: 0 else: 1
  if port < lo or port > 65535:
    quit "port out of range (" & $lo & "-65535): " & s
  Port(port)

proc parseDest*(dest: string): (string, Port) =
  var
    host = "127.0.0.1"
    portStr = dest
  let i = dest.rfind(':')
  if i >= 0:
    if i > 0:
      host = dest[0 ..< i]
    portStr = dest[i + 1 .. ^1]
  if portStr == "" or not allCharsInSet(portStr, {'0' .. '9'}):
    quit "dest needs a port, got: " & dest
  (host, parsePort(portStr))

iterator cmdOpts*(
    args: seq[string], shortNoVal: set[char] = {}, longNoVal: seq[string] = @[]
): (CmdLineKind, string, string) =
  ## Option iteration for subcommands. Guards a parseopt footgun:
  ## initOptParser on an EMPTY seq silently re-reads the real command
  ## line, re-feeding the dispatched command name as an argument.
  if args.len > 0:
    var p = initOptParser(args, shortNoVal = shortNoVal, longNoVal = longNoVal)
    while true:
      p.next()
      if p.kind == cmdEnd:
        break
      yield (p.kind, p.key, p.val)

proc eachValue*(input: File, action: proc(v: Value)) =
  ## Drives `action` over a concatenation of values (the .blb / wire
  ## format). Quits with a message on malformed input.
  ##
  ## Reads with raw read(2), not stdio fread: fread on a pipe blocks
  ## until the WHOLE buffer fills or EOF, which would wedge live
  ## pipelines (bl listen | bl x) that never close.
  var sd = initStreamDecoder(maxValueBytes = high(int) div 2)
  var buf = newSeq[byte](16 * 1024)
  let fd = input.getFileHandle
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0:
      if errno == EINTR:
        continue
      quit "read failed: " & $strerror(errno)
    if n == 0:
      break
    sd.feed(buf.toOpenArray(0, n - 1))
    while true:
      let v =
        try:
          sd.next()
        except DecodeError as e:
          quit "input isn't a value stream: " & e.msg
      if v.isNone:
        break
      action(v.get)
  if sd.buffered > 0:
    quit "input ends mid-value (" & $sd.buffered & " incomplete bytes)"

proc seededRand*(seed: int, given: bool): Rand =
  ## Sampling repeats exactly when you say which run you want. When you
  ## don't, it picks one and says which, so any run can be had again --
  ## a generator whose default is one fixed answer is not a generator.
  var s = seed
  if not given:
    var pick = initRand()
    s = pick.rand(int.high)
    stderr.writeLine "-- seed " & $s
  initRand(s)

proc emit*(v: Value) =
  ## One value onto stdout, flushed. A filter in a live pipeline must
  ## pass each value on now, not when its stdio buffer happens to fill.
  let ce = encode(v)
  if stdout.writeBuffer(addr ce[0], ce.len) != ce.len:
    quit "short write to stdout"
  stdout.flushFile()

proc runFilter*[T: ValueLike](f: proc(v: Value): Option[T]) =
  ## Lifts a function from values to ValueLikes into a
  ## stdin -> stdout stream filter.
  ## None drops the value indicating refusal;
  ## everything else is one value in, one out.
  ## ie:
  ## bl listen | bl x | ...
  mixin toValue
  eachValue(
    stdin,
    proc(v: Value) =
      let o = f(v)
      if o.isSome:
        emit o.get.toValue
    ,
  )
