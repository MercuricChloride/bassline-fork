## TCP sockets at the edge
##
## A connection carries a bare concatenation of CE-encoded values. A
## listener hands each value that arrives to a local send, and nothing
## about the connection goes with it. Where bytes came from, and how a
## connection ended, go only to an optional observer, for chatter.
##
## Malformed input is fatal to a connection's reading: past one bad
## byte there is no sound resync point. A listener then closes it.

import std/[asyncnet, asyncdispatch, nativesockets, sequtils, tables]
import ../core
export asyncnet, asyncdispatch

const
  RecvChunk = 16 * 1024
  ## how much to pull from the socket at once; the decoder buffers the
  ## rest, and refuses a value past `MaxValueBytes`

type
  EdgeKind* = enum
    edgeOpen = "open"            ## a connection opened
    edgeClose = "close"          ## a connection closed, however it ended
    edgeTruncated = "truncated"  ## the other end stopped partway through
                                 ## a value
    edgeMalformed = "malformed"  ## the decoder refused the bytes: the
                                 ## grammar, or a size cap
    edgeFailed = "failed"        ## the socket or the send raised

  EdgeEvent* = object
    kind*: EdgeKind
    address*: string       ## the other end's address; the listener's
                           ## own, for an accept that failed
    error*: ref Exception  ## why, for `edgeMalformed` and `edgeFailed`

  Observer* = proc(e: EdgeEvent)
    ## hears what happens at the edge; never handed a value

  ViewSend = proc(view: ValueView)

  Conn* = ref object
    socket: AsyncSocket
    address: string
    decoder: Decoder
    observe: Observer
    lastWrite: Future[void]
    writeFailed: bool

  Listener* = ref object
    socket: AsyncSocket
    address: string
    send: ViewSend
    observe: Observer
    connId: int
    connections: Table[int, Conn]

proc `$`*(e: EdgeEvent): string =
  result = $e.kind & " " & e.address
  if e.error != nil:
    result.add ": " & e.error.msg

proc tell(observe: Observer, address: string, kind: EdgeKind,
          error: ref Exception = nil) =
  ## An observer that raises has nowhere to be reported, so it is
  ## ignored rather than let it take the connection down.
  if observe != nil:
    try: observe(EdgeEvent(kind: kind, address: address, error: error))
    except Exception: discard

template closingOnError(socket: AsyncSocket, body: untyped) =
  try:
    body
  except CatchableError:
    socket.close() # asyncnet has no finalizer; the fd would leak
    raise

# ================ CONN ================

proc tell(conn: Conn, kind: EdgeKind, error: ref Exception = nil) =
  conn.observe.tell(conn.address, kind, error)

proc newConn(socket: AsyncSocket, address: string, observe: Observer): Conn =
  result = Conn(socket: socket, address: address, decoder: newDecoder(),
                observe: observe)
  result.tell edgeOpen

proc isClosed*(conn: Conn): bool =
  conn.socket.isClosed

proc close*(conn: Conn) =
  ## Writes still queued are dropped; `flush` first to keep them.
  if not conn.socket.isClosed:
    conn.socket.close()
    conn.tell edgeClose

proc transmit(conn: Conn, data: string) {.async.} =
  ## A write to an end that has gone away fails rather than being
  ## swallowed, so later writes are refused. Reading goes on
  ## regardless.
  try:
    await conn.socket.send(data, flags = {})
  except CatchableError as e:
    if not conn.isClosed and not conn.writeFailed:
      conn.writeFailed = true
      conn.tell edgeFailed, e

proc write*(conn: Conn, ce: openArray[byte]): bool =
  ## Queues CE bytes for the other end and answers whether they were
  ## accepted for sending: yes while the connection is open and no
  ## write on it has failed. Writes on one Conn go out whole and in
  ## order bc the dispatcher runs a socket's write callbacks in turn.
  if conn.isClosed or conn.writeFailed:
    return false
  conn.lastWrite = conn.transmit(ce.toString)
  true

proc write*(conn: Conn, v: Value): bool =
  conn.write(v.ce)

proc sender*(conn: Conn): proc(v: Value): bool =
  ## A send that writes each value's CE to `conn`.
  result = proc(v: Value): bool = conn.write(v)

proc flush*(conn: Conn) {.async.} =
  ## Done once every write queued so far has gone out or failed.
  if conn.lastWrite != nil:
    await conn.lastWrite

proc toViewSend(send: proc(v: Value): bool): ViewSend =
  result = proc(view: ValueView) = discard send(view.toValue)

proc toViewSend(send: proc(ce: openArray[byte]): bool): ViewSend =
  result = proc(view: ValueView) = discard send(view.ce)

proc pump(conn: Conn, send: ViewSend) {.async.} =
  ## Drives the connection, handing every value that arrives on it to
  ## send in order until closed.
  ##
  ## Reading stops when the other end closes, at malformed input, at a
  ## send that raises, or at a failed socket, each told to the
  ## observer, a close partway through a value as truncated. Stopping
  ## reads closes nothing: writing on is up to whoever holds the Conn.
  ##
  ## The decoder is drained whole each turn, each value handed on while
  ## its view is live, then the buffer is compacted, so a long run of
  ## input stays bounded.
  try:
    while not conn.isClosed:
      let data = await conn.socket.recv(RecvChunk)
      if data.len == 0: # the other end closed
        if conn.decoder.pending:
          conn.tell edgeTruncated
        return
      conn.decoder.buf.add(data.toBytes)
      for view in conn.decoder.checked:
        if conn.isClosed: # closed while a send ran; nothing more goes on
          return
        try:
          send(view)
        except Exception as e:
          # Exception since a Defect in a send (ie a bad index) is
          # still that connection's problem, not the listener's
          conn.tell edgeFailed, e
          return
      conn.decoder.compact()
  except CodecError as e:
    conn.tell edgeMalformed, e
  except CatchableError as e:
    if not conn.isClosed: # else closed from our side
      conn.tell edgeFailed, e

proc pump*(conn: Conn, send: proc(v: Value): bool): Future[void] =
  ## Hands every value that arrives on `conn` to `send` until reading
  ## stops.
  conn.pump(toViewSend send)

proc pump*(conn: Conn, send: proc(ce: openArray[byte]): bool): Future[void] =
  ## As above, but `send` gets each value's CE bytes, so a relay need
  ## not build a `Value`.
  conn.pump(toViewSend send)

proc connect*(host: string, port: Port,
              observe: Observer = nil): Future[Conn] {.async.} =
  ## Opens a connection to `host` and `port`.
  let socket = newAsyncSocket(buffered = false)
  closingOnError socket:
    await socket.connect(host, port)
  return newConn(socket, host & ":" & $port, observe)

# ================ LISTENER ================

proc close*(l: Listener) =
  ## Stop accepting, and close the connections it accepted, since
  ## nothing else holds them.
  if not l.socket.isClosed:
    l.socket.close()
  for conn in toSeq(l.connections.values):
    conn.close()

proc port*(l: Listener): Port =
  l.socket.getLocalAddr()[1]

proc process(l: Listener, id: int, conn: Conn) {.async.} =
  ## The listener never writes, so once reading stops the connection
  ## is done.
  try:
    await conn.pump(l.send)
  finally:
    l.connections.del id
    conn.close()

proc track(l: Listener, conn: Conn) =
  let id = l.connId
  inc l.connId
  l.connections[id] = conn
  asyncCheck l.process(id, conn)

proc addressOf(client: AsyncSocket, fallback: string): string =
  try:
    let (host, port) = client.getPeerAddr()
    host & ":" & $port
  except OSError: # the other end may already be gone
    fallback

proc serve*(l: Listener) {.async.} =
  ## The accept loop. Runs until the listener is closed.
  while not l.socket.isClosed:
    var accepted: tuple[address: string, client: AsyncSocket]
    try:
      accepted = await l.socket.acceptAddr()
    except CatchableError as e:
      if l.socket.isClosed:
        break
      l.observe.tell(l.address, edgeFailed, e)
      # so we don't hot-spin on a persistent accept failure
      await sleepAsync(100)
      continue
    if l.socket.isClosed: # closed while the accept was on its way here
      accepted.client.close()
      break
    let address = addressOf(accepted.client, accepted.address)
    l.track newConn(accepted.client, address, l.observe)

proc listener(port: Port, send: ViewSend, observe: Observer,
              address: string): Listener =
  ## Binds a listening socket.
  ##
  ## Sockets are unbuffered bc asyncnet's buffered recv loops until it
  ## fills the full requested size, stalling on inputs smaller than
  ## the chunk. Accepted sockets inherit the listener's flag, and the
  ## decoder buffers for itself anyway.
  let socket = newAsyncSocket(buffered = false)
  var bound: string
  closingOnError socket:
    socket.setSockOpt(OptReuseAddr, true)
    socket.bindAddr(port, address)
    socket.listen()
    let (host, p) = socket.getLocalAddr()
    bound = host & ":" & $p
  Listener(socket: socket, address: bound, send: send, observe: observe)

proc newListener*(port: Port, send: proc(v: Value): bool,
                  observe: Observer = nil, address = ""): Listener =
  ## Binds a listening socket; every value that arrives goes to `send`.
  listener(port, toViewSend send, observe, address)

proc newListener*(port: Port, send: proc(ce: openArray[byte]): bool,
                  observe: Observer = nil, address = ""): Listener =
  ## As above, but `send` gets each value's CE bytes, so a relay need
  ## not build a `Value`.
  listener(port, toViewSend send, observe, address)
