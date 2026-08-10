include pkg/prelude

import std/[asyncnet, asyncdispatch, sets, options]

import pkg/core
import pkg/lib/[reader, msg, msgchan]

const RecvChunk = 16 * 1024

type
  ServerP* = ref object
    socket*: AsyncSocket
    maxDepth*: int
    maxValueBytes*: int
    onConnect*: proc(conn: ChanP): Future[void]
    onError*: proc(conn: ChanP, e: ref Exception)
    onClose*: proc(conn: ChanP)
    connections*: HashSet[ChanP]

# ================ Socket Chan ================

proc newSocket*(
    socket: AsyncSocket, maxDepth = 64, 
    maxValueBytes = DefaultMaxValueBytes
): ChanP =
  var
    decoder = initStreamDecoder(maxDepth, maxValueBytes)
    s = ChanP()
  
  result = s

  proc recv(): Future[MaybeMsg] {.async.} =
    try:
      while not socket.isClosed:
        let value = decoder.next()
        if value.isSome:
          return some msg(s, value.get)
        let data = await socket.recv(RecvChunk)
        if data.len == 0:
          return none Msg
        decoder.feed(data.toOpenArrayByte(0, data.high))
    except OSError:
      return none Msg
  s.sendAsync = proc(m: Msg) {.async.} =
    if socket.isClosed: return
    await socket.send(encodeToString(m.value))
  s.close = proc() = socket.close()
  s.recv = recv

# ================ Server Interactions ================

proc accept(s: ServerP): Future[ChanP] {.async.} =
  newSocket(await s.socket.accept(), s.maxDepth, s.maxValueBytes)

proc handleClient(s: ServerP, client: ChanP) {.async.} =
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
  doAssert s.onError != nil, "server missing onError"
  doAssert s.onClose != nil, "server missing onClose"
  
  echo "starting server..."
  while not s.socket.isClosed:
    try:
      let client = await s.accept()
      asyncCheck s.handleClient(client)
    except OSError:
      if s.socket.isClosed: break 
      else: raise
  echo "server closed"

# ================ Constructors ================

proc newServer*(
  maxDepth = 64, 
  maxValueBytes = DefaultMaxValueBytes
): ServerP =
  result = ServerP(
    socket: newAsyncSocket(buffered = false),
    maxDepth: maxDepth,
    maxValueBytes: maxValueBytes
  )
  result.onError = proc(conn: ChanP, e: ref Exception) =
    echo "error: ", e.msg
    conn.close()
  result.onClose = proc(conn: ChanP) =
    echo "client closed"

# ================ Connections ================

proc connect*(
    host: string, port: Port, 
    maxDepth = 64, 
    maxValueBytes = DefaultMaxValueBytes
): Future[ChanP] {.async.} =
  let sock = newAsyncSocket(buffered = false)
  await sock.connect(host, port)
  newSocket(sock, maxDepth, maxValueBytes)

when isMainModule:
  var 
    myServer = newServer()
    socket = myServer.socket

  myServer.onConnect =
    proc(conn: ChanP) {.async.} =
      echo "new connection!"
      var m: MaybeMsg
      while true:
        m = await conn.recv()
        if m.isNone: break
        echo "\nSERVER GOT: ", m.get.value
        conn.send(msg sym"hello from server")
      echo "connection closed"

  socket.setSockOpt(OptReuseAddr, true)
  socket.bindAddr(Port(12345))
  socket.listen()

  proc doPoll() {.async.} =
    while not myServer.socket.isClosed:
      echo "connections: ", myServer.connections.len
      await sleepAsync(500)

  proc doClient() {.async.} =
    let (host, port) = myServer.socket.getLocalAddr()
    let client = await connect(host, port)
    client.send(msg sym"hello from client")
    var m: MaybeMsg
    m = await client.recv()
    echo "\nCLIENT GOT: ", m.get().value
    await sleepAsync(1000)
    client.close()

  asyncCheck doPoll()

  asyncCheck myServer.serve()

  for _ in 1 .. 5:
    asyncCheck doClient()

  runForever()