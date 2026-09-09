## A landing surface for bassline values
##
## A connection carries a bare concatenation of CE-encoded values.
## The surface hands each landed value to a callback as a `Msg` whose
## reply speaks CE back on the same socket.

import std/[asyncnet, asyncdispatch, nativesockets, tables]
import ../[core, msg]
export asyncnet, asyncdispatch, msg

const
  RecvChunk = 16 * 1024
  ## how much to pull from the socket at once; the decoder buffers the
  ## rest, and refuses a value past `MaxValueBytes`

type
  Conn* = ref object
    socket: AsyncSocket
    address*: string
    decoder: Decoder
    pool: TaskPool

  Handler* = proc(msg: Msg): Future[void]
  ConnCallback* = proc(conn: Conn)
  ErrorCallback* = proc(conn: Conn, error: ref Exception) {.gcsafe.}

  Landing* = ref object
    socket: AsyncSocket
    onMsg: Handler
    onOpen: ConnCallback
    onClose: ConnCallback
    onError: ErrorCallback
    connId: int
    connections*: Table[int, Future[void]]

# ================ CONN ================

proc close*(conn: Conn) =
  if not conn.socket.isClosed:
    conn.socket.close()

proc isClosed*(conn: Conn): bool =
  conn.socket.isClosed

proc send*(conn: Conn, value: Value): Future[void] {.async.} =
  ## Speak one value to the peer
  ## Concurrent sends on one Conn don't interleave bytes bc the
  ## dispatcher queues whole-buffer writes per socket.
  await conn.socket.send(value.ce.toString)

proc pump*(conn: Conn, onValue: proc(v: Value): Future[void]) {.async.} =
  ## Drives the connection passing every value from the connection
  ## into onValue in order until closed. 
  ## 
  ## Malformed input raises a `CodecError` and closes the connection
  ##
  ## The decoder is drained whole each turn with completed values copied out,
  ## then the buffer is compacted, so a long stream stays bounded.
  while not conn.socket.isClosed:
    var data: string
    try:
      data = await conn.socket.recv(RecvChunk)
    except OSError:
      if conn.socket.isClosed: return # closed from our side
      raise
    if data.len == 0: return # peer closed
    conn.decoder.buf.add(data.toBytes)
    var batch: seq[Value]
    for view in conn.decoder.checked:
      batch.add view.toValue
    conn.decoder.compact()
    for v in batch:
      await onValue(v)

proc connect*(host: string, port: Port): Future[Conn] {.async.} =
  ## Opens a connection to a landing
  let 
    socket = newAsyncSocket(buffered = false)
    decoder = newDecoder()
  try:
    await socket.connect(host, port)
  except CatchableError:
    socket.close()
    raise
  return Conn(socket: socket, address: host, decoder: decoder)

# ================ LANDING ================

proc close*(l: Landing) =
  ## Stop accepting.
  ## Established connections are left alone so
  ## close those if you care
  if not l.socket.isClosed:
    l.socket.close()

proc port*(l: Landing): Port =
  l.socket.getLocalAddr()[1]

proc nextConnId(l: Landing): int =
  result = l.connId
  inc l.connId

proc handleErr(l: Landing, conn: Conn, err: ref Exception) =
  if l.onError != nil:
    l.onError(conn, err)
  else:
    raise err

proc handleOpen(l: Landing, conn: Conn) =
  if l.onOpen != nil:
    l.onOpen(conn)

proc handleClose(l: Landing, conn: Conn) =
  if l.onClose != nil:
    l.onClose(conn)

proc replyTo(conn: Conn): Send =
  ## A unilateral reply path for one connection: whole-value CE sends,
  ## their futures kept by the conn's pool so a close loses none and a
  ## failed send is reported through the pool's `onFail`.
  conn.pool.bridge(proc(m: Msg): Future[void] = conn.send(m.value))

proc process(l: Landing, conn: Conn) {.async.} =
  ## Drives the logic for connection
  ## If the handler blows up it closes the
  ## connection, not the whole landing surface
  conn.pool = newTaskPool(proc(e: ref Exception) = l.handleErr(conn, e))
  let onReply = conn.replyTo
  try:
    l.handleOpen(conn)
    await conn.pump(proc(v: Value) {.async.} =
      await l.onMsg(newMsg(v, onReply, -1)))
  except Exception as e:
    # Exception since a Defect in a handler (ie a bad index)
    # is still that connection's problem, not the landings
    l.handleErr(conn, e)
  finally:
    await conn.pool.drain()
    try: conn.close()
    except: discard
    try: l.handleClose(conn)
    except: discard

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
    let
      id = l.nextConnId
      conn = Conn(
        socket: accepted.client,
        address: accepted.address,
        decoder: newDecoder())
      fut = l.process(conn)
    
    l.connections[id] = fut
    fut.addCallback(
      proc() = l.connections.del id)

proc newLanding*(
    port: Port,
    onMsg: Handler,
    onOpen: ConnCallback = nil,
    onClose: ConnCallback = nil,
    onError: ErrorCallback = nil,
    address = "",
): Landing =
  ## Binds a listening socket for values to land on.
  let socket = newAsyncSocket(buffered = false)
  try:
    socket.setSockOpt(OptReuseAddr, true)
    socket.bindAddr(port, address)
    socket.listen()
  except CatchableError:
    socket.close()
    raise
  Landing(
    socket: socket,
    onMsg: onMsg,
    onOpen: onOpen,
    onClose: onClose,
    onError: onError,
  )