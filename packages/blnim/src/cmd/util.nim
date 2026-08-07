import std/[strutils, nativesockets, options, parseopt, os, posix, random]
import pkg/core
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

type
  ReachKind* = enum
    rkUnix
    rkTcp
    rkSsh

  Reach* = object
    ## A local description of somewhere bytes can land. It belongs to
    ## the CLI: it is never inserted into values and is not an identity.
    case kind*: ReachKind
    of rkUnix:
      path*: string
    of rkTcp:
      host*: string
      port*: Port
    of rkSsh:
      sshDest*: string # host or user@host, ssh's business
      remote*: string # the reach spelling handed to the remote bl

proc parseReach*(s: string): Reach =
  ## unix:/path, tcp://host:port, ssh://host/path; an absolute path is
  ## a unix socket convenience, and bare port / host:port spellings
  ## stay compatible with the TCP commands.
  if s.len == 0:
    quit "empty reach"
  if s.startsWith("unix:"):
    Reach(kind: rkUnix, path: s[5 .. ^1])
  elif s.startsWith("tcp://"):
    let (host, port) = parseDest(s[6 .. ^1])
    Reach(kind: rkTcp, host: host, port: port)
  elif s.startsWith("ssh://"):
    let rest = s[6 .. ^1]
    let slash = rest.find('/')
    if slash <= 0:
      quit "ssh reach wants ssh://host/path, got: " & s
    Reach(kind: rkSsh, sshDest: rest[0 ..< slash], remote: rest[slash .. ^1])
  elif s[0] == '/' or s.startsWith("./"):
    Reach(kind: rkUnix, path: s)
  else:
    let (host, port) = parseDest(s)
    Reach(kind: rkTcp, host: host, port: port)

proc `$`*(r: Reach): string =
  case r.kind
  of rkUnix: "unix:" & r.path
  of rkTcp: "tcp://" & r.host & ":" & $int(r.port)
  of rkSsh: "ssh://" & r.sshDest & r.remote

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

proc eachValueTicking*(
    input: File, action: proc(v: Value), everyMs: int, tick: proc()
) =
  ## `eachValue`, but `tick` also runs whenever `everyMs` goes by with
  ## nothing to read, and once more at the end.
  ##
  ## A reader on a pipe that never closes has to be able to act on what
  ## it already has; waiting for the end is waiting forever. The quiet
  ## is also what makes the acting safe -- a burst that is still
  ## arriving is not yet a thing to judge complete.
  var sd = initStreamDecoder(maxValueBytes = high(int) div 2)
  var buf = newSeq[byte](64 * 1024)
  let fd = input.getFileHandle
  var pfd = TPollfd(fd: cint(fd), events: POLLIN, revents: 0)
  while true:
    let ready = posix.poll(addr pfd, Tnfds(1), cint(everyMs))
    if ready < 0:
      if errno == EINTR:
        continue
      quit "poll failed: " & $strerror(errno)
    if ready == 0:
      tick()
      continue
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
  tick()

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

const WriterBuf = 256 * 1024

type ValueWriter* = object
  ## A bounded staging area in front of a File, so `encodeInto` never has
  ## to hold a whole encoding. Headers, names and keys accumulate; a piece
  ## already at least as big as the buffer goes straight to the descriptor
  ## uncopied, so a large payload is never doubled to be written.
  f: File
  buf: seq[byte]

proc writerOn*(f: File): ValueWriter =
  ValueWriter(f: f, buf: newSeqOfCap[byte](WriterBuf))

proc put(w: var ValueWriter, p: pointer, n: int) =
  if w.f.writeBuffer(p, n) != n:
    quit "short write to output"

proc flush*(w: var ValueWriter) =
  if w.buf.len > 0:
    w.put(addr w.buf[0], w.buf.len)
    w.buf.setLen(0)

proc write*(w: var ValueWriter, b: byte) =
  w.buf.add b
  if w.buf.len >= WriterBuf:
    w.flush()

proc write*(w: var ValueWriter, bytes: openArray[byte]) =
  if bytes.len == 0:
    return
  if bytes.len >= WriterBuf:
    # big enough to be its own write; staging it would only copy it
    w.flush()
    w.put(addr bytes[0], bytes.len)
  else:
    let start = w.buf.len
    w.buf.setLen(start + bytes.len)
    copyMem(addr w.buf[start], addr bytes[0], bytes.len)
    if w.buf.len >= WriterBuf:
      w.flush()

proc writeValue*(w: var ValueWriter, v: Value) =
  ## `v` onto the writer. Nothing beyond the staging buffer is held.
  encodeInto(v, w)

var stdoutWriter = writerOn(stdout)

proc emit*(v: Value) =
  ## One value onto stdout, flushed. A filter in a live pipeline must
  ## pass each value on now, not when its stdio buffer happens to fill.
  stdoutWriter.writeValue v
  stdoutWriter.flush()
  stdout.flushFile()

proc runFilter*(f: proc(v: Value): Option[Value]) =
  ## Lifts a partial function into a
  ## stdin -> stdout stream filter.
  ## None drops the value indicating refusal;
  ## everything else is one value in, one out.
  ## ie:
  ## bl listen | bl x | ...
  eachValue(
    stdin,
    proc(v: Value) =
      let o = f(v)
      if o.isSome:
        emit o.get
  )
