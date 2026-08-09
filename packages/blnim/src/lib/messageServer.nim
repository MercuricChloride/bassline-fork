include pkg/prelude

import std/[asyncnet, asyncdispatch, sets, options]

import pkg/core
import pkg/lib/[messages, reader]

const RecvChunk = 16 * 1024

type
  SocketP = ref object of Place
    socket*: AsyncSocket
    decoder*: StreamDecoder
  
  ServerP = ref object of SocketP
    maxDepth: int
    maxValueBytes: int
    onConnect*: proc(conn: SocketP): Future[void]
    onError*: proc(conn: SocketP, e: ref Exception)
    onClose*: proc(conn: SocketP)
    connections*: HashSet[SocketP]

# ================ Socket Interaction ================

proc isClosed*(conn: SocketP): bool =
  conn.socket.isClosed()

proc close*(conn: SocketP) =
  if not conn.isClosed:
    conn.socket.close()

proc receive*(conn: SocketP): Future[Option[Msg]] {.async.} =
  ## Receive a value from a socket
  while true:
    let value = conn.decoder.next()
    if value.isSome:
      return some msg(conn, value.get)
    let data = await conn.socket.recv(RecvChunk)
    if data.len == 0:
      return none Msg
    conn.decoder.feed(data.toOpenArrayByte(0, data.high))

# ================ Server Interaction ================

proc newSocket*(
    socket: AsyncSocket, maxDepth = 64, 
    maxValueBytes = DefaultMaxValueBytes
): SocketP

proc accept(s: ServerP): Future[SocketP] {.async.} =
  newSocket(await s.socket.accept(), s.maxDepth, s.maxValueBytes)

proc listen(s: ServerP) =
  s.socket.listen()

proc handleClient(s: ServerP, client: SocketP) {.async.} =
  try:
    s.connections.incl client
    await s.onConnect(client)
  except CatchableError as e:
    s.onError(client, e)
  finally:
    s.onClose(client)
    s.connections.excl client
    client.close()

proc serve(s: ServerP) {.async.} =
  doAssert s.onConnect != nil, "server missing onConnect"
  echo "starting server..."
  while not s.isClosed:
    try:
      let client = await s.accept()
      asyncCheck s.handleClient(client)
    except OSError:
      if s.isClosed: break 
      else: raise
  echo "server closed"

# ================ Constructors ================

proc newSocket*(
    socket: AsyncSocket, maxDepth = 64, 
    maxValueBytes = DefaultMaxValueBytes
): SocketP =
  result = SocketP(
    socket: socket, 
    decoder: initStreamDecoder(maxDepth, maxValueBytes)
  )
  result.sendAsync = proc(m: Msg) {.async.} =
    if socket.isClosed: return
    await socket.send(encodeToString(m.value))

proc newServer*(
  maxDepth = 64, 
  maxValueBytes = DefaultMaxValueBytes
): ServerP =
  result = ServerP(
    socket: newAsyncSocket(buffered = false),
    maxDepth: maxDepth,
    maxValueBytes: maxValueBytes
  )
  result.onError = proc(conn: SocketP, e: ref Exception) =
    echo "error: ", e.msg
    conn.socket.close()
  result.onClose = proc(conn: SocketP) =
    echo "client closed"
  result.send = proc(m: Msg) =
    echo "server was directly sent a message... why?"
    echo m.value

# ================ Connections ================

proc connect*(
    host: string, port: Port, 
    maxDepth = 64, 
    maxValueBytes = DefaultMaxValueBytes
): Future[SocketP] {.async.} =
  let sock = newAsyncSocket(buffered = false)
  await sock.connect(host, port)
  newSocket(sock, maxDepth, maxValueBytes)

when isMainModule:
  var myServer = newServer()
  myServer.socket.setSockOpt(OptReuseAddr, true)
  myServer.socket.bindAddr(Port(12345))
  myServer.listen()

  myServer.onConnect =
    proc(conn: SocketP) {.async.} =
      echo "new connection!"
      while not conn.isClosed:
        var m = await conn.receive()
        if m.isNone: break
        echo "SERVER GOT: ", m.get.value
        conn.send(msg sym"hello from server")
      echo "connection closed"

  proc doPoll() {.async.} =
    while not myServer.isClosed:
      echo "connections: ", myServer.connections.len
      await sleepAsync(500)

  proc doClient() {.async.} =
    let (host, port) = myServer.socket.getLocalAddr()
    let client = await connect(host, port)
    client.send(msg sym"hello from client")
    var m: Option[Msg]
    m = await client.receive()
    echo "CLIENT GOT: ", m.get().value
    await sleepAsync(1000)
    client.close()

  asyncCheck doPoll()

  asyncCheck myServer.serve()

  myServer.send(msg text"hello")

  for _ in 1 .. 5:
    asyncCheck doClient()

  runForever()