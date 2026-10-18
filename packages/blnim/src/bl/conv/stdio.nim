##[
  Standard input and output as participants. `input` says each value
  that arrives on stdin, a bare concatenation of CE, into every
  conversation it is in, and leaves them when stdin ends. `inputFrom`
  does the same for a file. `output` writes each value it is sent to
  stdout as CE.
]##
import std/[deques, nativesockets, oserrors, posix]
import ../core
import ./conv

const Chunk = 16 * 1024

type
  Input* = ref object of Speaker
    fd: cint
    owned: bool  ## whether it opened `fd`, and so closes it
    reading: bool
    done*: Future[void]
      ## complete once its input ends. It fails if the input ends inside
      ## a value or holds bytes that are not CE, since nothing past them
      ## reads

  Output* = ref object of Participant
    queue: Deque[seq[byte]]  ## what stdout hasn't taken yet
    writing: bool
    flushed: Future[void]

let
  input* = Input(fd: STDIN_FILENO, done: newFuture[void]("stdin"))
  output* = Output()

proc isPipe(fd: cint): bool =
  ## whether `fd` is a pipe or a socket, which the dispatcher can watch
  var st: Stat
  fd.fstat(st) == 0 and (st.st_mode.S_ISFIFO or st.st_mode.S_ISSOCK)

proc ready(fd: cint, write: bool): Future[void] =
  ## done once `fd` can be read or written without waiting
  let f = newFuture[void]("ready")
  let cb = proc(fd: AsyncFD): bool =
    f.complete
    true
  if write: AsyncFD(fd).addWrite cb
  else: AsyncFD(fd).addRead cb
  f

# ================
# Input
# ================

proc inputFrom*(path: string): Input =
  ## a participant that says each value in the file at `path`
  let fd = posix.open(path.cstring, O_RDONLY)
  if fd < 0: raiseOSError(osLastError(), path)
  Input(fd: fd, owned: true, done: newFuture[void](path))

proc read(p: Input) {.async.} =
  ## A file, or a device like /dev/null, always has bytes or its end, and
  ## the dispatcher can't watch it, so it is read directly. Either way it
  ## yields first, so whoever joins next hears it all.
  let waits = p.fd.isPipe or p.fd.isatty == 1
  var
    decoder = newDecoder()
    chunk = newSeq[byte](Chunk)
  if waits: AsyncFD(p.fd).register
  try:
    while true:
      if waits: await p.fd.ready(write = false)
      else: await sleepAsync(0)
      let n = posix.read(p.fd, addr chunk[0], chunk.len)
      if n < 0:
        if errno in [EINTR, EAGAIN]: continue
        raiseOSError osLastError()
      if n == 0: break
      decoder.buf.add chunk.toOpenArray(0, n - 1)
      for view in decoder.checked:
        p.say view.toValue
      decoder.compact
    if decoder.pending:
      raise newException(CodecError, "the input ended inside a value")
    p.done.complete
  except CatchableError as e:
    p.done.fail e
  if waits: AsyncFD(p.fd).unregister
  if p.owned: discard posix.close(p.fd)
  p.leaveAll

method joined*(p: Input, r: Room) =
  procCall Speaker(p).joined(r)
  if not p.reading:
    p.reading = true
    asyncCheck p.read

# ================
# Output
# ================

proc write(p: Output) {.async.} =
  ## Writes what is queued, in order. Into a pipe or a socket it waits
  ## for room without holding anyone up, the pipe left waiting only while
  ## there is something to write. A terminal or a file takes each write
  ## at once. A write that fails drops what is queued and fails `flush`.
  let waits = STDOUT_FILENO.isPipe
  var failed: ref CatchableError
  if waits:
    AsyncFD(STDOUT_FILENO).register
    SocketHandle(STDOUT_FILENO).setBlocking(false)
  try:
    while p.queue.len > 0:
      let data = p.queue.peekFirst
      var at = 0
      while at < data.len:
        if waits: await STDOUT_FILENO.ready(write = true)
        let n = posix.write(STDOUT_FILENO, addr data[at], data.len - at)
        if n < 0:
          if errno in [EINTR, EAGAIN]: continue
          raiseOSError osLastError()
        at += n
      p.queue.popFirst
  except CatchableError as e:
    failed = e
    p.queue.clear
  if waits:
    AsyncFD(STDOUT_FILENO).unregister
    SocketHandle(STDOUT_FILENO).setBlocking(true)
  p.writing = false
  if not p.flushed.isNil:
    if failed.isNil: p.flushed.complete
    else: p.flushed.fail failed

method send*(p: Output, msg: Msg) =
  p.queue.addLast msg.value.ce
  if not p.writing:
    p.writing = true
    p.flushed = nil
    asyncCheck p.write

proc flush*(p: Output): Future[void] =
  ## done once everything `p` was sent has gone out. A program waits on it
  ## before it ends, or what is still queued is lost
  if not p.writing:
    result = newFuture[void]("flush")
    result.complete
  else:
    if p.flushed.isNil: p.flushed = newFuture[void]("flush")
    result = p.flushed
