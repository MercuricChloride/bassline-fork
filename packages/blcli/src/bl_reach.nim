## bl reach: a byte pump between a place and stdin/stdout, or a command

import std/[net, os, posix]
import harness

type Mode = enum
  duplex, source, sink

proc connectTo(place: Place): Socket =
  ## a blocking socket to a TCP place; one that can't be reached is fatal
  try:
    # dial makes the socket for whichever family the host resolves to
    result = dial(place.host, place.port, buffered = false)
  except CatchableError as e:
    fail "can't reach " & $place & ": " & e.msg

proc pump(sock: cint, mode: Mode) =
  ## stdin into the place and the place onto stdout, either half alone
  ## under --source or --sink, bytes as they come, never decoded. The
  ## end of stdin closes the speaking half; the hearing half lasts until
  ## the place ends it. A place that stops taking bytes ends speaking.
  ##
  ## The socket doesn't block: what the place hasn't taken yet waits in
  ## `owed`, and stdin isn't read again until it has gone, while the
  ## place is heard all the while. A place that speaks more than it
  ## hears then can't wedge both sides on full buffers. select, not
  ## poll: poll on macOS refuses terminals.
  var
    buf = newSeq[byte](ReadChunk)
    owed: seq[byte] # read from stdin, not yet taken by the place
    taken = 0
    speaking = mode != sink
    hearing = mode != source
  if not speaking:
    discard shutdown(SocketHandle(sock), SHUT_WR)
  discard fcntl(sock, F_SETFL, fcntl(sock, F_GETFL) or O_NONBLOCK)
  template stopSpeaking() =
    speaking = false
    owed.setLen 0
    discard shutdown(SocketHandle(sock), SHUT_WR)
  while speaking or hearing:
    var canRead, canWrite: TFdSet
    FD_ZERO(canRead)
    FD_ZERO(canWrite)
    if speaking and owed.len == 0: FD_SET(cint(0), canRead)
    if speaking and owed.len > 0: FD_SET(sock, canWrite)
    if hearing: FD_SET(sock, canRead)
    if select(sock + 1, addr canRead, addr canWrite, nil, nil) < 0:
      if errno == EINTR: continue
      fail "select failed: " & $strerror(errno)
    if speaking and owed.len > 0 and FD_ISSET(sock, canWrite) != 0:
      let n = posix.write(sock, addr owed[taken], owed.len - taken)
      if n >= 0:
        taken += n
        if taken == owed.len:
          owed.setLen 0
          taken = 0
      elif errno == EPIPE or errno == ECONNRESET:
        stopSpeaking()
      elif errno notin [EINTR, EAGAIN, EWOULDBLOCK]:
        fail "can't write to the place: " & $strerror(errno)
    if speaking and owed.len == 0 and FD_ISSET(cint(0), canRead) != 0:
      let n = stdinSource().readSome(addr buf[0], buf.len)
      if n == 0:
        stopSpeaking()
      else:
        owed = buf[0 ..< n]
    if hearing and FD_ISSET(sock, canRead) != 0:
      let n = posix.read(sock, addr buf[0], buf.len)
      if n > 0:
        emit buf.toOpenArray(0, n - 1)
      elif n == 0 or errno == ECONNRESET:
        hearing = false
      elif errno notin [EINTR, EAGAIN, EWOULDBLOCK]:
        fail "can't read from the place: " & $strerror(errno)

proc commandArgv(command: seq[string]): seq[string] =
  ## A path runs as it is. A name runs as `bl NAME` would, so the
  ## dispatcher itself resolves it: a builtin, else bl-NAME on PATH.
  if '/' in command[0]: command
  else: @[getAppFilename()] & command

proc reachArgs(mode: Mode): seq[string] =
  case mode
  of duplex: @[]
  of source: @["--source"]
  of sink: @["--sink"]

proc overSsh(place: Place, mode: Mode, command: seq[string]) =
  ## Without a command, becomes `ssh HOST bl reach PLACE`. With one,
  ## starts ssh and the command on a pair of pipes between them, as
  ## though the far place were the command's stdin and stdout, and stays
  ## to hear how both end: the command's status, or 1 if ssh failed.
  let argv = sshArgv(place, reachArgs(mode))
  if command.len == 0:
    execTool argv
  var toFar, fromFar: array[2, cint]
  if pipe(toFar) != 0 or pipe(fromFar) != 0:
    fail "can't make a pipe: " & $strerror(errno)
  let all = [toFar[0], toFar[1], fromFar[0], fromFar[1]]
  let far = spawn(argv,
                  stdinFd = (if mode != sink: toFar[0] else: -1),
                  stdoutFd = (if mode != source: fromFar[1] else: -1),
                  closing = all)
  let cmd = spawn(commandArgv(command),
                  stdinFd = (if mode != source: fromFar[0] else: -1),
                  stdoutFd = (if mode != sink: toFar[1] else: -1),
                  closing = all)
  for fd in all:
    discard posix.close(fd)
  let cmdStatus = waitExit(cmd)
  let farStatus = waitExit(far)
  if cmdStatus != 0:
    quit cmdStatus
  if farStatus != 0:
    fail "ssh to " & $place & " ended with status " & $farStatus
  quit 0

proc run(t: Tool, a: Args) =
  if a.positional.len != 1:
    t.misuse "takes exactly one place"
  if a.has("source") and a.has("sink"):
    t.misuse "--source and --sink each leave out a half; give one at most"
  let mode = if a.has("source"): source elif a.has("sink"): sink else: duplex
  let place =
    try: parsePlace(a.positional[0])
    except ValueError as e: t.misuse e.msg
  if place.kind == sshPlace:
    overSsh(place, mode, a.command)

  let socket = connectTo(place)
  let sock = cint(socket.getFd)
  if a.command.len == 0:
    pump(sock, mode)
    return
  # the place becomes the command's stdin and stdout; nothing of reach
  # stays behind
  case mode
  of duplex:
    discard dup2(sock, 0)
    discard dup2(sock, 1)
  of source:
    discard dup2(sock, 1)
  of sink:
    discard shutdown(SocketHandle(sock), SHUT_WR)
    discard dup2(sock, 0)
  if sock > 2:
    discard posix.close(sock)
  execTool commandArgv(a.command)

let tool* = Tool(
  name: "reach",
  args: "PLACE [-- CMD ARGS…]",
  summary: "a byte pump between a place and stdin/stdout, or a command",
  about: """
PLACE is tcp://host:port, host:port, :port or a bare port (host
127.0.0.1), or ssh://host/PLACE, which runs `bl reach PLACE` on the far
side, PLACE being a TCP place there (ssh://host alone reaches the far
side's """ & DefaultPlace & """). reach copies bytes and never decodes them:
whatever is at the place judges what it gets.

With no command, stdin goes into the place and whatever the place
speaks comes out on stdout; the end of stdin closes the speaking half,
and reach ends when the place closes the other. With `-- CMD ARGS…` the
place becomes CMD's stdin and stdout and reach becomes CMD (over ssh://
reach stays, and exits with CMD's status, or 1 if ssh failed). A CMD
with a slash runs as it is; a name runs as `bl NAME` would.""",
  opts: @[
    Opt(long: "source", help: "only speak: stdin (or CMD's stdout) to the place"),
    Opt(long: "sink", help: "only hear: the place to stdout (or CMD's stdin)")],
  command: true,
  run: run)
