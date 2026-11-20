import std/[asyncdispatch, asyncnet, nativesockets]
import bassline
export asyncdispatch, asyncnet

const
  RecvChunk = 16 * 1024
  KeepIdle = 30
  KeepInterval = 10
  KeepProbes = 3

var
  TCP_KEEPINTVL {.importc, header: "<netinet/tcp.h>".}: cint
  TCP_KEEPCNT {.importc, header: "<netinet/tcp.h>".}: cint
when defined(macosx):
  var TCP_KEEPIDLE {.importc: "TCP_KEEPALIVE", header: "<netinet/tcp.h>".}: cint
else:
  var TCP_KEEPIDLE {.importc, header: "<netinet/tcp.h>".}: cint

type
  Conn* = ref object of Live
    into*: Track
    address*: string
    why*: string

  TcpConn* = ref object of Conn
    socket: AsyncSocket
    reader: Reader
    lastWrite: Future[void]

  Listener* = ref object of Track
    socket: AsyncSocket

method send*(c: Conn, ce: sink string) {.base.} =
  discard

method close*(c: Conn) {.base.} =
  discard

method isClosed*(c: Conn): bool {.base.} =
  false

method reified*(c: Conn): Value =
  let address = Text(c.address)
  if c.why.len > 0:
    let why = Text(c.why)
    toValue bl"(connection $address $why)"
  else:
    toValue bl"(connection $address)"

proc connection*(n: Node): Conn =
  case n
  of Bound(l):
    if l of Conn:
      result = Conn(l)
  of Plain:
    discard

proc keepAlive(socket: AsyncSocket) =
  # probes an end that went quiet, so one that went away without closing
  # ends the connection within a minute or so. The other end may be gone
  # already, so a socket that won't take the options is left as it is
  try:
    socket.setSockOpt(OptKeepAlive, true)
    let fd = socket.getFd
    fd.setSockOptInt(toInt(IPPROTO_TCP), TCP_KEEPIDLE, KeepIdle)
    fd.setSockOptInt(toInt(IPPROTO_TCP), TCP_KEEPINTVL, KeepInterval)
    fd.setSockOptInt(toInt(IPPROTO_TCP), TCP_KEEPCNT, KeepProbes)
  except OSError:
    discard

method isClosed*(c: TcpConn): bool =
  c.socket.isClosed

method close*(c: TcpConn) =
  if not c.socket.isClosed:
    c.socket.close

proc transmit(c: TcpConn, ce: string) {.async.} =
  try:
    await c.socket.send(ce, flags = {})
  except CatchableError as e:
    if not c.isClosed:
      c.why = "failed: " & e.msg
      c.close

method send*(c: TcpConn, ce: sink string) =
  # sends on one connection go out whole and in order, since the dispatcher
  # runs a socket's sends in turn
  if not c.isClosed:
    c.lastWrite = c.transmit(ce)

proc write*(c: Conn, n: Node) =
  var ce: string
  n.write(ce)
  c.send ce

proc flush*(c: TcpConn) {.async.} =
  if not c.lastWrite.isNil:
    await c.lastWrite

proc read*(c: TcpConn) {.async.} =
  # what a track's hooks raise ends reading this connection, and nothing more
  if c.into.isNil:
    c.close
    return
  try:
    while not c.isClosed:
      let data = await c.socket.recv(RecvChunk)
      if data.len == 0:
        if c.reader.starved:
          c.why = "truncated"
        return
      for v in c.reader.readEach(data):
        if c.isClosed:
          return
        try:
          c.into.add v.toNode
        except CatchableError as e:
          c.why = "failed: " & e.msg
          return
  except BasslineError as e:
    c.why = "malformed: " & e.msg
  except CatchableError as e:
    if not c.isClosed:
      c.why = "failed: " & e.msg

proc connect*(host: string, port: Port): Future[TcpConn] {.async.} =
  let socket = newAsyncSocket(buffered = false)
  try:
    await socket.connect(host, port)
  except CatchableError:
    socket.close
    raise
  socket.keepAlive
  return TcpConn(socket: socket, address: host & ":" & $port, reader: initReader())

proc newListener*(host: string, port: Port): Listener =
  # unbuffered, since asyncnet's buffered recv waits to fill the whole chunk,
  # and the reader buffers for itself
  let socket = newAsyncSocket(buffered = false)
  try:
    socket.setSockOpt(OptReuseAddr, true)
    socket.bindAddr(port, host)
    socket.listen
  except CatchableError:
    socket.close
    raise
  Listener(socket: socket)

proc port*(l: Listener): Port =
  l.socket.getLocalAddr[1]

proc close*(l: Listener) =
  if not l.socket.isClosed:
    l.socket.close
  for i in 0 ..< l.len:
    case l[i]
    of Present(n):
      let c = n.connection
      if not c.isNil:
        c.close
    of Absent:
      discard

proc hold(l: Listener, i: int, c: TcpConn) {.async.} =
  # a listener holds a connection while it reads from it. What its monitors
  # raise is theirs, and doesn't stop the listener
  await c.read
  try:
    l.reviseIt:
      it.delete(i)
  except CatchableError:
    discard

proc serve*(l: Listener) {.async.} =
  while not l.socket.isClosed:
    var accepted: tuple[address: string, client: AsyncSocket]
    try:
      accepted = await l.socket.acceptAddr
    except CatchableError:
      if l.socket.isClosed:
        break
      await sleepAsync(100)
      continue
    if l.socket.isClosed:
      accepted.client.close
      break
    let address =
      try:
        let (host, port) = accepted.client.getPeerAddr
        host & ":" & $port
      except OSError:
        accepted.address
    accepted.client.keepAlive
    let c = TcpConn(socket: accepted.client, address: address, reader: initReader())
    try:
      l.add c.toNode
    except CatchableError:
      discard
    asyncCheck l.hold(l.len - 1, c)
