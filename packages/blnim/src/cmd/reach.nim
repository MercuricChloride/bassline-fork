import std/[os, posix, net]
import ./util

const help = """
bl reach [--source|--sink] PLACE [-- COMMAND ARGS...]

Gives a process surface to a place. PLACE is a local reach:
unix:/path or an absolute path, tcp://host:port or host:port,
or ssh://host/path (which runs bl reach on the far side).

Without a command, stdin is spoken into the place while whatever
the place speaks arrives on stdout. reach copies bytes; it never
decodes values. The place judges its own landing.

With a command, the place becomes the command's stdin and stdout
and reach execs it -- no relay process remains. A command with no
slash resolves like a subcommand: bl-COMMAND on PATH, else the
bundled COMMAND.

Options:
  --source   only speak: stdin (or the command's stdout) goes to
             the place; nothing is read back
  --sink     only hear: the place goes to stdout (or the command's
             stdin); nothing is spoken
"""

type Mode = enum
  mDuplex
  mSource
  mSink

proc writeAll(fd: cint, buf: pointer, n: int) =
  var done = 0
  while done < n:
    let w = posix.write(fd, cast[pointer](cast[int](buf) + done), n - done)
    if w < 0:
      if errno == EINTR:
        continue
      if errno == EPIPE:
        quit 0 # downstream is gone; a pump with no mouth is finished
      quit "write failed: " & $strerror(errno)
    done += w

proc pump(sock: cint, mode: Mode) =
  ## The raw connector: stdin -> place and place -> stdout, either
  ## half alone under a projection. EOF on the speaking side closes
  ## that half; the hearing side stays until the place ends it.
  var buf: array[16 * 1024, byte]
  var speaking = mode != mSink
  var hearing = mode != mSource
  if not speaking:
    discard posix.shutdown(SocketHandle(sock), SHUT_WR)
  while speaking or hearing:
    var fds: array[2, TPollfd]
    var n = 0
    var stdinAt = -1
    var sockAt = -1
    if speaking:
      fds[n] = TPollfd(fd: 0, events: POLLIN, revents: 0)
      stdinAt = n
      inc n
    if hearing:
      fds[n] = TPollfd(fd: sock, events: POLLIN, revents: 0)
      sockAt = n
      inc n
    if poll(addr fds[0], Tnfds(n), -1) < 0:
      if errno == EINTR:
        continue
      quit "poll failed: " & $strerror(errno)
    if stdinAt >= 0 and (fds[stdinAt].revents and (POLLIN or POLLHUP)) != 0:
      let got = posix.read(0, addr buf[0], buf.len)
      if got < 0:
        if errno != EINTR:
          quit "read failed: " & $strerror(errno)
      elif got == 0:
        speaking = false
        discard posix.shutdown(SocketHandle(sock), SHUT_WR)
      else:
        writeAll(sock, addr buf[0], got)
    if sockAt >= 0 and (fds[sockAt].revents and (POLLIN or POLLHUP)) != 0:
      let got = posix.read(sock, addr buf[0], buf.len)
      if got < 0:
        if errno != EINTR:
          quit "read failed: " & $strerror(errno)
      elif got == 0:
        hearing = false # this local stream ended; that is all it means
      else:
        writeAll(1, addr buf[0], got)

proc connectFd(r: Reach): cint =
  case r.kind
  of rkUnix:
    let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    try:
      sock.connectUnix(r.path)
    except OSError as e:
      quit "can't reach " & $r & " -- " & e.msg
    cint(sock.getFd())
  of rkTcp:
    let sock = newSocket()
    try:
      sock.connect(r.host, r.port)
    except OSError as e:
      quit "can't reach " & $r & " -- " & e.msg
    cint(sock.getFd())
  of rkSsh:
    quit "unreachable" # ssh is exec'd before connecting

proc execArgv(argv: seq[string]) {.noreturn.} =
  let cargs = allocCStringArray(argv)
  discard execv(argv[0].cstring, cargs)
  quit "cannot exec " & argv[0] & ": " & $strerror(errno)

proc sshArgv(r: Reach, mode: Mode): seq[string] =
  result = @["ssh", r.sshDest, "bl", "reach"]
  case mode
  of mSource:
    result.add "--source"
  of mSink:
    result.add "--sink"
  of mDuplex:
    discard
  result.add r.remote

proc childArgv(cmd: string, args: seq[string]): seq[string] =
  ## The same resolution as the dispatcher: bl-CMD on PATH, else the
  ## bundled command through our own binary. A slash means exactly
  ## that executable.
  if '/' in cmd:
    return @[cmd] & args
  let ext = findExe("bl-" & cmd)
  if ext.len > 0:
    return @[ext] & args
  @[getAppFilename(), cmd] & args

proc run*(args: seq[string]) =
  var connectorArgs = args
  var child: seq[string]
  let sep = args.find("--")
  if sep >= 0:
    connectorArgs = args[0 ..< sep]
    child = args[sep + 1 .. ^1]
    if child.len == 0:
      quit "-- wants a command after it\n\n" & help

  var
    place = ""
    mode = mDuplex
  for kind, key, val in cmdOpts(
    connectorArgs, shortNoVal = {'h'}, longNoVal = @["help", "source", "sink"]
  ):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "source":
        mode = mSource
      of "sink":
        mode = mSink
      else:
        quit "unknown reach option: " & key & "\n\n" & help
    else:
      if place != "":
        quit "reach takes one place\n\n" & help
      place = key
  if place == "":
    quit "reach needs a place\n\n" & help

  let r = parseReach(place)

  if r.kind == rkSsh:
    if child.len > 0:
      quit "reach over ssh doesn't take a command yet; " &
        "run it on the far side: ssh HOST bl reach PATH -- CMD"
    let argv = sshArgv(r, mode)
    let exe = findExe("ssh")
    if exe.len == 0:
      quit "no ssh on PATH"
    execArgv(@[exe] & argv[1 .. ^1])

  signal(SIGPIPE, SIG_IGN)
  let sock = connectFd(r)

  if child.len > 0:
    # the place becomes the command's process surface; nothing remains
    # of reach itself
    case mode
    of mDuplex:
      discard dup2(sock, 0)
      discard dup2(sock, 1)
    of mSource:
      discard dup2(sock, 1)
    of mSink:
      discard dup2(sock, 0)
    if sock > 2:
      discard posix.close(sock)
    execArgv(childArgv(child[0], child[1 .. ^1]))

  pump(sock, mode)
