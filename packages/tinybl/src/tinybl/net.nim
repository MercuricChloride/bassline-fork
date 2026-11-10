##[
A socket as two ends of events. Values emitted into `outgoing` are
written to the socket as ce, and the bytes that arrive are read by a
builder and emitted from `incoming`.

Closing `outgoing` shuts the socket's write side once everything
emitted before it has been written. Closing `incoming` shuts the read
side. The other way round works the same. When the other end stops
sending, `incoming` closes, and when a write fails, `outgoing` closes.
The socket itself closes once both sides are done.

Nothing is read until something listens to `incoming`, so what arrives
first waits in the socket rather than being emitted to no one. A side
that never listens closes `incoming`, or `done` waits on it.

A name on this machine is a unix socket that one process listens on,
found by the name alone: `hold` takes it, `dial` connects to whoever
holds it. Each name is files in a directory, `~/.bl/running` unless
another is given: NAME.lock, locked by the holder for as long as it
runs, NAME.sock beside it, and NAME.blb, a value describing what is
held there, if the holder gave one. A name is a file name, not
beginning with a dot and not digits alone, which are the pids bl jam
says what it runs under in the same directory. The kernel lets the lock go when
the holder dies, however it dies, so a name left by a holder that died
is free again. `about` reads what describes a name, and `names` lists
the names held.

The files go when the name does. `close` takes them away, and for a
holder that stops without closing, killed or crashed or interrupted, a
watcher does: a small process `hold` starts, apart from the holder and
its terminal, which waits for the holder to be gone and then takes away
the files of the name it held, unless someone holds it again by then.
Should the watcher be gone too, the next to hold the name takes them.

A proxy puts a place elsewhere, a host and a port, at a name on this
machine. `proxy` holds the name, with its own description, and joins
each connection made to it to a new connection to the place. Bytes go
through as they are. When one side stops sending, the other is told
nothing more comes, and a pair closes once neither side has more to
say. A place that can't be reached closes the connection made to the
name. Closing the proxy gives the name up and ends every pair, and
`done` completes once they have all ended.
]##
import std/[asyncdispatch, asyncnet, nativesockets, oserrors, options, os]
from std/strutils import allCharsInSet, Digits
from std/posix import shutdown, signal, SHUT_RD, SHUT_WR, SHUT_RDWR, EAGAIN, EWOULDBLOCK, ENOBUFS, EINTR,
  O_RDWR, O_CREAT, O_CLOEXEC, S_IRUSR, S_IWUSR, Stat
import ./[events, ce]
export events, options

refuseWith BasslineError

const RecvSize* {.intdefine.} = 64 * 1024

type
  Writer = ref object
    ## bytes going out on one socket, in the order they were given: values
    ## emitted into outgoing, as ce, and bytes handed to `send`
    pending: string         ## given and not yet written, from `sent` on
    sent: int
    signal: Future[void]    ## set while the writer waits for more

  EventSocket*[T] = object
    sock: AsyncSocket
    writer: Writer
    writes: Listener[T]     ## the writer's end of outgoing
    incoming*: Source[T]
    outgoing*: Emitter[T]
    finished: Future[void]

proc encodeInbox[T](w: Writer, writes: Listener[T], outgoing: Emitter[T]) =
  ## appends the listeners inbox values to the writers pending bytes.
  ## If a BasslineError occurs due to codec refusals its bytes are cut
  ## and everything emitted after it is dropped and the outgoing emitter closes
  for v in writes:
    let before = w.pending.len
    try:
      w.pending.writeCE(v)
    except BasslineError:
      w.pending.setLen before
      outgoing.close
      for _ in writes: discard
      return

proc wake(w: Writer) =
  if not w.signal.isNil:
    let f = w.signal
    w.signal = nil
    f.complete()

proc writable(fd: AsyncFD): Future[void] =
  ## completes once fd can take more
  let f = newFuture[void]("writable")
  addWrite(fd, proc(fd: AsyncFD): bool =
    f.complete()
    true)
  f

proc flush(w: Writer, fd: AsyncFD) {.async.} =
  ## writes everything pending to fd. 
  ## This waits if the socket is full or if the kernel is out of buffers. 
  ## Full socket (EAGAIN, EWOULDBLOCK) is waited on
  ## Kernel out of buffers (ENOBUFS) retries
  ## Otherwise this raises
  while w.sent < w.pending.len:
    let n = posix.send(fd.SocketHandle, readRawData(w.pending, w.sent),
      w.pending.len - w.sent, MSG_NOSIGNAL)
    if n > 0:
      w.sent += n
      # drop what is written, so a writer that never quite catches up
      # doesn't hold everything it ever wrote
      if w.sent * 2 >= w.pending.len:
        let rest = w.pending.len - w.sent
        if rest > 0:
          let p = beginStore(w.pending, w.pending.len)
          moveMem(p, addr p[w.sent], rest)
          endStore(w.pending)
        w.pending.setLen rest
        w.sent = 0
      continue
    let e = osLastError()
    if e.cint in [EAGAIN, EWOULDBLOCK]: await writable(fd)
    elif e.cint == ENOBUFS: await sleepAsync(1)
    elif e.cint != EINTR: raiseOSError(e)

proc recvTask[T; B: Builder[T]](
    sock: AsyncSocket, builder: B, incoming: Emitter[T]) {.async.} =
  ## reads values off sock and emits them until either side stops
  var
    r = initReader[T, B](builder)
    buf = newString(RecvSize)
  try:
    await incoming.ready
    while not incoming.isDone:
      let n = await recvInto(sock.getFd.AsyncFD, beginStore(buf, RecvSize), RecvSize)
      endStore(buf)
      if n == 0: break
      var pos = 0
      while r.readCE(buf.toOpenArray(0, n - 1), pos):
        if not incoming.emit(move r.value): break
  except CatchableError: 
    discard
  incoming.close

proc encodeInboxTask[T](w: Writer, writes: Listener[T], outgoing: Emitter[T]) {.async.} =
  ## encodes what is emitted as it comes, and wakes the writer
  while not writes.closed:
    await writes.ready
    w.encodeInbox(writes, outgoing)
    w.wake

proc writeTask[T](w: Writer, writes: Listener[T], outgoing: Emitter[T], fd: AsyncFD) {.async.} =
  ## writes what is given until outgoing closes or the other end is gone,
  ## then shuts the socket's write side
  try:
    while true:
      w.encodeInbox(writes, outgoing)
      if w.sent < w.pending.len:
        await w.flush(fd)
      elif writes.closed:
        break
      else:
        w.signal = newFuture[void]("writer")
        await w.signal
  except CatchableError:
    discard
  outgoing.close
  discard shutdown(fd.SocketHandle, SHUT_WR)

proc wrapSocket*[T: Walkable; B: Builder[T]](
    sock: AsyncSocket, builder: B, keepAlive = true, maxQueueSize = -1): EventSocket[T] =
  ## `sock` as events, values arriving made by `builder`
  let
    incoming = newEmitter[T](maxQueueSize)
    outgoing = newEmitter[T](-1)
    writes = outgoing.listen
    writer = Writer()
  # closing incoming wakes a recv that is waiting, which then reads nothing
  incoming.done.addCallback(proc() = discard shutdown(sock.getFd, SHUT_RD))
  sock.setSockOpt(OptKeepAlive, keepAlive)
  when defined(macosx):
    # a write to a peer that has gone raises an error, not SIGPIPE
    setSockOptInt(sock.getFd, SOL_SOCKET, SO_NOSIGPIPE, 1)
  asyncCheck encodeInboxTask(writer, writes, outgoing)
  let finished =
    recvTask(sock, builder, incoming) and writeTask(writer, writes, outgoing, sock.getFd.AsyncFD)
  finished.addCallback(proc() = sock.close)
  EventSocket[T](sock: sock, writer: writer, writes: writes, incoming: incoming.source,
    outgoing: outgoing, finished: finished)

proc wrapSocket*[T: Walkable](
    sock: AsyncSocket, keepAlive = true, maxQueueSize = -1): EventSocket[T] =
  ## `sock` as events of a type that builds itself
  wrapSocket(sock, ByType[T](), keepAlive, maxQueueSize)

proc done*[T](self: EventSocket[T]): Future[void] =
  ## completes once both sides are done and the socket is closed
  self.finished

proc close*[T](self: EventSocket[T]) =
  self.incoming.close
  self.outgoing.close

proc sendRaw*[T](self: EventSocket[T], data: string): bool {.discardable.} =
  ## writes data as given, after every value emitted before it, until
  ## outgoing closes
  let w = self.writer
  w.encodeInbox(self.writes, self.outgoing)
  if self.outgoing.isDone:
    return false
  w.pending.add data
  w.wake
  true

proc send*[T](self: EventSocket[T], val: sink T): bool {.discardable.} =
  self.outgoing.emit(val)

# ================
# Names on this machine
# ================

var
  LOCK_EX {.importc, header: "<sys/file.h>".}: cint
  LOCK_NB {.importc, header: "<sys/file.h>".}: cint

proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}

type NamedSocket* = object
  ## a socket listening under a name this process holds, until it closes
  ## it or stops running
  sock*: AsyncSocket
  lock: cint
  watcher: cint  ## this end of the pipe the watcher waits on, or -1
  at: string  ## the path of its files, without their extensions

proc runningDir*(): string =
  ## where names on this machine are held
  getHomeDir() / ".bl" / "running"

proc pathOf(name, dir: string): string =
  guard name.len > 0 and name[0] != '.' and '/' notin name and '\0' notin name,
    "a name is a file name, not beginning with a dot: " & name
  guard not name.allCharsInSet(Digits),
    "a name of digits alone is a pid's, where bl jam says what it runs: " & name
  dir / name

proc sameFile(fd: cint, path: string): bool =
  ## whether the file open on fd is still the one at path
  var a, b: Stat
  posix.fstat(fd, a) == 0 and posix.stat(path, b) == 0 and
    a.st_dev == b.st_dev and a.st_ino == b.st_ino

converter toAsyncSocket*(named: NamedSocket): AsyncSocket =
  named.sock

proc lockFile(path: string): cint =
  ## an fd holding the file at path locked, made if it isn't there, or -1
  ## if a living process holds it. Only a holder takes a lock file away,
  ## so one taken away after it was opened here is tried again
  while true:
    let fd = posix.open(path, O_RDWR or O_CREAT or O_CLOEXEC, S_IRUSR or S_IWUSR)
    if fd < 0:
      raiseOSError(osLastError(), path)
    if flock(fd, LOCK_EX or LOCK_NB) != 0:
      let e = osLastError()
      discard posix.close(fd)
      if e.cint == EWOULDBLOCK:
        return -1
      raiseOSError(e, path)
    if fd.sameFile(path):
      return fd
    discard posix.close(fd)

proc takeAway(lockPath, sockPath, aboutPath: string) =
  ## takes a name's files away, unless a living process holds it
  let fd = posix.open(lockPath, O_RDWR)
  if fd >= 0 and flock(fd, LOCK_EX or LOCK_NB) == 0 and fd.sameFile(lockPath):
    discard posix.unlink(sockPath)
    discard posix.unlink(aboutPath)
    discard posix.unlink(lockPath)

proc watch(at: string): cint =
  ## starts a watcher for the name whose files are at `at`, answering the
  ## end of the pipe it waits on, to be kept open for as long as the name
  ## is held, or -1 if none could start. Its paths are made before it
  ## starts, so the watcher makes nothing
  let
    lockPath = at & ".lock"
    sockPath = at & ".sock"
    aboutPath = at & ".blb"
  var ends: array[2, cint]
  if posix.pipe(ends) != 0:
    return -1
  let child = posix.fork()
  if child == 0:
    # the watcher is the child's child, so no one waits for it to end,
    # and in a session of its own, so Ctrl-C in a terminal doesn't reach
    # it. It keeps nothing of the holder's open but its end of the pipe,
    # which reads nothing until the holder's end closes
    if posix.fork() == 0:
      discard posix.setsid()
      for fd in 0 ..< posix.sysconf(posix.SC_OPEN_MAX).cint:
        if fd != ends[0]:
          discard posix.close(fd)
      var b: char
      while posix.read(ends[0], addr b, 1) < 0 and posix.errno == EINTR:
        discard
      takeAway(lockPath, sockPath, aboutPath)
    posix.exitnow(0)
  discard posix.close(ends[0])
  if child < 0:
    discard posix.close(ends[1])
    return -1
  var status: cint
  discard posix.waitpid(child, status, 0)
  # so that programs the holder starts don't keep the watcher waiting
  discard posix.fcntl(ends[1], posix.F_SETFD, posix.FD_CLOEXEC)
  ends[1]

proc holdAs(name, dir, about: string): Option[NamedSocket] =
  ## hold, `about` the CE of the value describing what is held, or empty
  let at = pathOf(name, dir)
  createDir(dir)
  let lock = lockFile(at & ".lock")
  if lock < 0:
    return none(NamedSocket)
  let sock = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    # what a holder that died left is replaced or taken away, and what
    # describes the name is there before anyone can connect
    discard tryRemoveFile(at & ".sock")
    if about.len > 0:
      writeFile(at & ".blb.new", about)
      moveFile(at & ".blb.new", at & ".blb")
    else:
      discard tryRemoveFile(at & ".blb")
    let mask = posix.umask(0o177)        # only this user may connect
    try:
      sock.bindUnix(at & ".sock")
    finally:
      discard posix.umask(mask)
    sock.listen
  except CatchableError:
    sock.close
    discard tryRemoveFile(at & ".blb")
    discard posix.close(lock)
    raise
  some NamedSocket(sock: sock, lock: lock, watcher: watch(at), at: at)

proc hold*(name: string, dir = runningDir()): Option[NamedSocket] =
  ## listens on a unix socket under `name` in `dir` until closed or until
  ## this process stops, or none if a living process holds the name
  holdAs(name, dir, "")

proc hold*[T: Walkable](name: string, about: T, dir = runningDir()): Option[NamedSocket] =
  ## hold, with `about` describing what is held there for whoever looks
  holdAs(name, dir, about.ce)

proc close*(s: NamedSocket) =
  ## stops listening and gives the name up, taking its files away. The
  ## lock file goes while still held, so no one else holds it meanwhile,
  ## and the watcher, finding it gone, leaves
  s.sock.close
  discard tryRemoveFile(s.at & ".sock")
  discard tryRemoveFile(s.at & ".blb")
  discard tryRemoveFile(s.at & ".lock")
  discard posix.close(s.lock)
  if s.watcher >= 0:
    discard posix.close(s.watcher)

proc dial*(name: string, dir = runningDir()): Future[AsyncSocket] {.async.} =
  ## a socket connected to whoever holds `name` in `dir`
  let sock = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    await sock.connectUnix(pathOf(name, dir) & ".sock")
  except CatchableError:
    sock.close
    raise
  sock

proc about*[T; B: Builder[T]](name: string, builder: B, dir = runningDir()): auto =
  ## the value describing what is held under `name` in `dir`, made by
  ## `builder`, or none if nothing describes it, or no one holds it
  mixin buildNull
  let bytes =
    try: readFile(pathOf(name, dir) & ".blb")
    except IOError: return none(T)
  var
    r = initReader[T, B](builder)
    pos = 0
  guard r.readCE(bytes, pos) and pos == bytes.len,
    name & ".blb is not one whole value"
  some move r.value

proc about*(T: typedesc[Walkable], name: string, dir = runningDir()): Option[T] =
  ## the value describing what is held under `name` in `dir`, or none
  about(name, ByType[T](), dir)

iterator names*(dir = runningDir()): string =
  ## the names held in `dir`, each as it was when it was looked at
  for kind, path in walkDir(dir):
    let (_, name, ext) = path.splitFile
    if kind != pcDir and ext == ".sock":
      yield name

iterator running*(T: typedesc[Walkable], dir = runningDir()): tuple[name: string, desc: T] =
  for name in names(dir):
    let desc = T.about(name, dir)
    guard desc.isSome, "couldnt read about"
    yield(name, desc.get)

# ================
# Proxies
# ================

type Proxy* = ref object
  ## a name on this machine whose connections are each joined to a new
  ## connection to a place elsewhere, until it is closed or this process
  ## stops
  named: NamedSocket
  host: string
  port: Port
  open: seq[AsyncSocket]  ## both sockets of every pair still joined
  closed: bool
  finished: Future[void]

proc pour(src, dst: AsyncSocket) {.async.} =
  ## writes what arrives on src to dst until src stops sending or dst
  ## takes no more. Then dst is told nothing more comes, and src is no
  ## longer read
  var buf = newString(RecvSize)
  try:
    while true:
      let n = await recvInto(src.getFd.AsyncFD, beginStore(buf, RecvSize), RecvSize)
      endStore(buf)
      if n == 0: break
      await send(dst.getFd.AsyncFD, readRawData(buf), n, {})
  except CatchableError:
    discard
  discard shutdown(dst.getFd, SHUT_WR)
  discard shutdown(src.getFd, SHUT_RD)

proc settle(p: Proxy) =
  if p.closed and p.open.len == 0 and not p.finished.finished:
    p.finished.complete()

proc close*(p: Proxy) =
  ## gives the name up and ends every pair still joined. Each pair's
  ## sockets close once what was on its way through has stopped
  if p.closed: return
  p.closed = true
  p.named.close
  for s in p.open:
    discard shutdown(s.getFd, SHUT_RDWR)
  p.settle

proc join(p: Proxy, near: AsyncSocket) {.async.} =
  ## near joined to a new connection to p's place, each side's bytes
  ## written to the other, until neither has more to say. When the place
  ## can't be reached, near closes
  var far: AsyncSocket
  try:
    far = await asyncnet.dial(p.host, p.port)
  except CatchableError:
    near.close
    return
  if p.closed:
    near.close
    far.close
    return
  when defined(macosx):
    for s in [near, far]:
      setSockOptInt(s.getFd, SOL_SOCKET, SO_NOSIGPIPE, 1)
  p.open.add near
  p.open.add far
  await pour(near, far) and pour(far, near)
  p.open.del p.open.find(near)
  p.open.del p.open.find(far)
  near.close
  far.close
  p.settle

proc serve(p: Proxy) {.async.} =
  ## joins each connection made to p's name, until p closes. A name
  ## that can no longer be answered is given up
  while not p.closed:
    let near =
      try: await p.named.sock.accept()
      except CatchableError:
        p.close
        break
    if p.closed:
      near.close
      break
    asyncCheck p.join(near)

proc proxyAs(name, dir, about, host: string, port: Port): Option[Proxy] =
  let named = holdAs(name, dir, about)
  if named.isNone:
    return none(Proxy)
  let p = Proxy(named: named.get, host: host, port: port,
                finished: newFuture[void]("proxy"))
  asyncCheck p.serve
  some p

proc proxy*(name, host: string, port: Port, dir = runningDir()): Option[Proxy] =
  ## holds `name` in `dir`, and joins each connection made to it to a new
  ## connection to host:port, or none if a living process holds the name
  proxyAs(name, dir, "", host, port)

proc proxy*[T: Walkable](name: string, about: T, host: string, port: Port,
                         dir = runningDir()): Option[Proxy] =
  ## proxy, with `about` describing what is held there for whoever looks
  proxyAs(name, dir, about.ce, host, port)

proc done*(p: Proxy): Future[void] =
  ## completes once p is closed and every pair it joined has ended
  p.finished