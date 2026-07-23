## A landing surface for bassline values
##
## A connection carries a bare concatenation of CE-encoded values.
## The surface hands each landed value to a callback along with the
## Conn it arrived on; what to retain, how to reply, and what anything
## means is the app's business. Replies are paired unilateral sends,
## not a request/response protocol.
##
## Malformed input is fatal to a connection: past one bad byte there
## is no sound resync point, so the socket is closed.

import std/[asyncnet, asyncdispatch, options]
import codec
export asyncnet, asyncdispatch, codec

const RecvChunk = 16 * 1024

type
  Conn* = ref object
    socket: AsyncSocket
    address*: string
    decoder: StreamDecoder

  Handler* = proc(conn: Conn, value: Value): Future[void]
  ConnCallback* = proc(conn: Conn)
  ErrorCallback* = proc(conn: Conn, error: ref Exception)

  Landing* = ref object
    socket: AsyncSocket
    onValue: Handler
    onOpen: ConnCallback
    onClose: ConnCallback
    onError: ErrorCallback
    maxDepth: int
    maxValueBytes: int

# ================ CONN ================

proc close*(conn: Conn) =
  if not conn.socket.isClosed:
    conn.socket.close()

proc isClosed*(conn: Conn): bool =
  conn.socket.isClosed

proc receive*(conn: Conn): Future[Option[Value]] {.async.} =
  ## The next value from the peer, or none once the connection is done.
  ## Malformed input raises DecodeError and the connection is
  ## then unusable for reading.
  while true:
    let value = conn.decoder.next()
    if value.isSome:
      return value
    let data = await conn.socket.recv(RecvChunk)
    if data.len == 0:
      return none Value
    conn.decoder.feed(data.toOpenArrayByte(0, data.high))

proc send*(conn: Conn, value: Value): Future[void] {.async.} =
  ## Speak one value to the peer. The value is encoded in full before
  ## anything is sent, so the wire never sees a partial emission.
  ## Concurrent sends on one Conn don't interleave bytes: the
  ## dispatcher queues whole-buffer writes per socket.
  await conn.socket.send(encodeToString(value))

proc connect*(
    host: string, port: Port, maxDepth = 64, maxValueBytes = DefaultMaxValueBytes
): Future[Conn] {.async.} =
  ## The client half: connect somewhere values are landing.
  let socket = newAsyncSocket(buffered = false)
  try:
    await socket.connect(host, port)
  except CatchableError:
    socket.close() # asyncnet has no finalizer; the fd would leak
    raise
  result = Conn(
    socket: socket, address: host, decoder: initStreamDecoder(maxDepth, maxValueBytes)
  )

# ================ LANDING ================

proc landing*(
    port: Port,
    onValue: Handler,
    onOpen: ConnCallback = nil,
    onClose: ConnCallback = nil,
    onError: ErrorCallback = nil,
    address = "",
    maxDepth = 64,
    maxValueBytes = DefaultMaxValueBytes,
): Landing =
  ## Binds a listening socket for values to land on.
  ##
  ## Sockets are unbuffered bc asyncnet's buffered recv loops until it
  ## fills the full requested size, stalling on inputs smaller than
  ## the chunk. Accepted sockets inherit the listener's flag, and the
  ## stream decoder buffers for itself anyway.
  let socket = newAsyncSocket(buffered = false)
  try:
    socket.setSockOpt(OptReuseAddr, true)
    socket.bindAddr(port, address)
    socket.listen()
  except CatchableError:
    socket.close() # asyncnet has no finalizer; the fd would leak
    raise
  Landing(
    socket: socket,
    onValue: onValue,
    onOpen: onOpen,
    onClose: onClose,
    onError: onError,
    maxDepth: maxDepth,
    maxValueBytes: maxValueBytes,
  )

proc localPort*(l: Landing): Port =
  l.socket.getLocalAddr()[1]

proc close*(l: Landing) =
  ## Stop accepting. Established connections are left alone; the app
  ## holds any Conns it cared to keep.
  if not l.socket.isClosed:
    l.socket.close()

proc process(l: Landing, conn: Conn) {.async.} =
  # nothing may escape into asyncCheck so a bug in one connection's
  # handler closes that connection, not the whole surface.
  # tbd if we are going to keep it like this or not
  try:
    if l.onOpen != nil:
      l.onOpen(conn)
    while true:
      let value = await conn.receive()
      if value.isNone:
        break
      await l.onValue(conn, value.get)
  except Exception as e:
    if l.onError != nil:
      try:
        l.onError(conn, e)
      except Exception:
        discard
  finally:
    try:
      conn.close()
    except Exception:
      discard
    if l.onClose != nil:
      try:
        l.onClose(conn)
      except Exception:
        discard

proc serve*(l: Landing) {.async.} =
  ## The accept loop. Runs until the landing is closed.
  while not l.socket.isClosed:
    var accepted: tuple[address: string, client: AsyncSocket]
    try:
      accepted = await l.socket.acceptAddr()
    except CatchableError:
      if l.socket.isClosed:
        break
      # so we don't hot-spin on a persistent accept failure
      await sleepAsync(100)
      continue
    let conn = Conn(
      socket: accepted.client,
      address: accepted.address,
      decoder: initStreamDecoder(l.maxDepth, l.maxValueBytes),
    )
    asyncCheck l.process(conn)
