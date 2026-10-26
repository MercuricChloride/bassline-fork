##[
A socket as two ends of events. Values emitted into `outgoing` are
written to the socket as ce, and the bytes that arrive are read by a
builder and emitted from `incoming`.

Closing `outgoing` shuts the socket's write side once everything
emitted before it has been written. Closing `incoming` shuts the read
side. The other way round works the same. When the other end stops
sending, `incoming` closes, and when a write fails, `outgoing` closes.
The socket itself closes once both sides are done.
]##
import std/[asyncdispatch, asyncnet, nativesockets, oserrors, streams]
from std/posix import shutdown, SHUT_RD, SHUT_WR, EAGAIN, EWOULDBLOCK, ENOBUFS, EINTR
import ./[events, ce]

const RecvSize* {.intdefine.} = 64 * 1024

type
  Writer = ref object
    ## bytes going out on one socket, in the order they were given: values
    ## emitted into outgoing, as ce, and bytes handed to `send`
    pending: StringStream   ## given and not yet written, from `sent` on
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
    let before = w.pending.data.len
    try:
      w.pending.writeStream(v)
    except BasslineError:
      w.pending.data.setLen before
      w.pending.setPosition before
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
  while w.sent < w.pending.data.len:
    let n = posix.send(fd.SocketHandle, addr w.pending.data[w.sent],
      w.pending.data.len - w.sent, MSG_NOSIGNAL)
    if n > 0:
      w.sent += n
      # drop what is written, so a writer that never quite catches up
      # doesn't hold everything it ever wrote
      if w.sent * 2 >= w.pending.data.len:
        let rest = w.pending.data.len - w.sent
        if rest > 0:
          moveMem(addr w.pending.data[0], addr w.pending.data[w.sent], rest)
        w.pending.data.setLen rest
        w.pending.setPosition rest
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
    s = newStringStream()
  try:
    while not incoming.isDone:
      s.data.setLen RecvSize
      let n = await recvInto(sock.getFd.AsyncFD, addr s.data[0], RecvSize)
      if n == 0: break
      s.data.setLen n
      s.setPosition 0
      while s.readStream(r):
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
      if w.sent < w.pending.data.len:
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
    writer = Writer(pending: newStringStream())
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

proc send*[T](self: EventSocket[T], data: string): bool {.discardable.} =
  ## writes data as given, after every value emitted before it, until
  ## outgoing closes
  let w = self.writer
  w.encodeInbox(self.writes, self.outgoing)
  if self.outgoing.isDone:
    return false
  w.pending.write(data)
  w.wake
  true