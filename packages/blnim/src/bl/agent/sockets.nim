import std/[asyncnet, oserrors]
from std/posix import shutdown, SHUT_WR
import ../core
import ./chan

# ================
# AsyncSocket Bridge
# ================

type Conn* = ref object
  incoming*, outgoing*: Chan[Value]
  sock*: AsyncSocket
  err*: ref Exception
  reading, writing: bool

const RecvChunk = 16 * 1024

proc fail(conn: Conn, e: ref Exception) =
  # once we closed the socket ourselves, what fails after is that close
  if conn.err.isNil and not conn.sock.isClosed:
    conn.err = e

proc settle(conn: Conn) =
  # the socket closes once both halves are done
  if not conn.reading and not conn.writing and not conn.sock.isClosed:
    conn.sock.close()

proc isDone*(conn: Conn): bool =
  not conn.reading and 
  not conn.writing and
  conn.sock.isClosed

proc sendTo(ch: Chan[Value], conn: Conn) {.async.} =
  try:
    ch.each val:
      if conn.sock.isClosed: break
      let bytes = val.ce
      await conn.sock.send(addr(bytes[0]), bytes.len, {})
    if not conn.sock.isClosed and shutdown(conn.sock.getFd, SHUT_WR) != 0:
      raiseOSError(osLastError())
  except CatchableError as e:
    conn.fail e
  finally:
    conn.writing = false
    conn.settle

proc pump(ch: Chan[Value], conn: Conn) {.async.} =
  var decoder = newDecoder()
  try:
    while true:
      let data = await conn.sock.recv(RecvChunk, {})
      if data.len == 0: break
      decoder.buf.add(data.toBytes)
      for view in decoder.checked:
        await ch.send(view.toValue)
      decoder.compact()
  except CatchableError as e:
    conn.fail e
  finally:
    ch.close
    conn.reading = false
    conn.settle

# ================
# Connection
# ================

proc newConn*(sock: AsyncSocket): Conn =
  let
    incoming = newChan(Value)
    outgoing = newChan(Value)
    conn = Conn(incoming: incoming, outgoing: outgoing, sock: sock,
                reading: true, writing: true)
  asyncCheck outgoing.sendTo(conn)
  asyncCheck incoming.pump(conn)
  conn

proc close*(self: Conn) =
  self.sock.close
  self.outgoing.close

proc drive*(
  self: Conn, 
  incoming, outgoing: 
    proc(ch: Chan[Value]): Future[void]) {.async.} =
  await incoming(self.incoming) and outgoing(self.outgoing)

proc connect*(host: string, port: Port): Future[Conn] {.async.} =
  let sock = newAsyncSocket(buffered = false)
  try:
    await sock.connect(host, port)
    return newConn(sock)
  except CatchableError:
    sock.close()
    raise

# ================
# Server
# ================

type
  Server* = ref object
    sock*: AsyncSocket
    clients*: seq[Conn]
    onConnect*: proc(s: Server, c: Conn): Future[void] {.nimcall.}
    listening: bool

proc newServer*(port: Port, onConnect: Server.onConnect = nil): Server =
  var sock = newAsyncSocket(buffered = false)
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(port)
  Server(sock: sock, onConnect: onConnect)

func listening*(self: Server): bool =
  self.listening

proc prune*(self: Server) =
  var clients: seq[Conn]
  for each in self.clients:
    if not each.isDone:
      clients.add each
  self.clients = clients

proc listen*(self: Server) {.async.} =
  if self.listening: return
  doAssert not isNil(self.onConnect)
  self.sock.listen()
  self.listening = true
  while not self.sock.isClosed:
    let client = newConn(await self.sock.accept())
    self.clients.add client
    asyncCheck self.onConnect(self, client)