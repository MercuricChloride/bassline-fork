include pkg/prelude

import std/[asyncnet, asyncdispatch, sets, options, net, os, posix]

import pkg/core
import pkg/lib/[reader, msg, msgchan]

const RecvChunk = 16 * 1024

type
  ServerP* = ref object
    socket*: AsyncSocket
    unixPath*: string
    maxDepth*: int
    maxValueBytes*: int
    onConnect*: proc(conn: ChanP): Future[void]
    onError*: proc(conn: ChanP, e: ref Exception)
    onClose*: proc(conn: ChanP)
    connections*: HashSet[ChanP]

# ================ Socket Chan ================

proc newSocket*(unix = false): AsyncSocket =
  if unix:
    newAsyncSocket(net.AF_UNIX, net.SOCK_STREAM, net.IPPROTO_IP, buffered = false)
  else:
    newAsyncSocket(buffered = false)

proc socketChan(
    socket: AsyncSocket, 
    maxDepth = 64, 
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

proc claimUnixPath(path: string) =
  ## Take the path only when it is a leftover stale socket.
  var st: Stat
  if lstat(path.cstring, st) != 0:
    return
  if not S_ISSOCK(st.st_mode):
    raise newException(OSError, path & " exists and is not a socket")
  if st.st_uid != getuid():
    raise newException(OSError, path & " is somebody else's socket")

  var sa: Sockaddr_un
  sa.sun_family = TSa_Family(posix.AF_UNIX)
  if path.len >= sa.sun_path.len:
    raise newException(OSError, "path too long for a unix socket: " & path)
  
  let fd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
  if cint(fd) < 0:
    raiseOSError(osLastError())
  defer:
    discard posix.close(cint(fd))
  copyMem(addr sa.sun_path[0], path.cstring, path.len + 1)
  if posix.connect(fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa))) == 0:
    raise newException(OSError, "a place is already listening on " & path)
  if osLastError() != OSErrorCode(ECONNREFUSED):
    raiseOSError(osLastError())
  removeFile(path)

# ================ Server Interactions ================


proc bindUnix*(s: ServerP, path: string) =
  ## Claims & binds the server to a unix socket at path.
  claimUnixPath(path)
  let oldMask = umask(0o177)
  try:
    asyncnet.bindUnix(s.socket, path)
  finally:
    discard umask(oldMask)
  s.unixPath = path

proc close*(s: ServerP) =
  ## Releases a path we took
  if not s.socket.isClosed:
    s.socket.close()
  if s.unixPath.len > 0:
    removeFile(s.unixPath)
    s.unixPath = ""

proc accept(s: ServerP): Future[ChanP] {.async.} =
  socketChan(await s.socket.accept(), s.maxDepth, s.maxValueBytes)

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
  socket: AsyncSocket,
  maxDepth = 64,
  maxValueBytes = DefaultMaxValueBytes,
): ServerP =
  result = ServerP(
    socket: socket,
    maxDepth: maxDepth,
    maxValueBytes: maxValueBytes
  )
  result.onError = proc(conn: ChanP, e: ref Exception) =
    echo "error: ", e.msg
    conn.close()
  result.onClose = proc(conn: ChanP) =
    echo "client closed"

when isMainModule:
  var
    socket = newSocket(unix = true)
    myServer = newServer(socket)

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

  myServer.bindUnix("/tmp/foo.sock")
  socket.listen()

  proc doStop() {.async.} =
    await sleepAsync(2000)
    myServer.close()

  proc doPoll() {.async.} =
    while not myServer.socket.isClosed:
      echo "connections: ", myServer.connections.len
      await sleepAsync(500)

  proc doClient() {.async.} =
    let sock = newSocket(unix = true)
    await sock.connectUnix("/tmp/foo.sock")
    let client = socketChan(sock)
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

  asyncCheck doStop()

  runForever()