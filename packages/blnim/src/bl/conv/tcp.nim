##[
  TCP sockets as participants. A `Wire` is one connection carrying a
  bare concatenation of CE. What it is sent goes out on it, and each
  value that arrives on it is said into every conversation it is in.

  When the other end stops sending, the wire stops reading and stays
  where it is, since the other end may still be listening. It leaves
  its conversations once a write fails. Once it is in no conversation
  it closes the socket, after what was written has gone out.
]##
import std/[asyncnet, sugar]
import ../core
import ./conv

export asyncnet

const Chunk = 16 * 1024

type
  Wire* = ref object of Speaker
    socket: AsyncSocket
    writing: Future[void]  ## the last write, done once all have gone

  Listener* = ref object
    socket: AsyncSocket

# ================
# Wire
# ================

proc finish(w: Wire) {.gcsafe.} =
  ## closes the socket once what was written to it has gone out, unless
  ## it has joined a conversation again meanwhile
  if w.socket.isClosed or w.rooms.len > 0: return
  if w.writing.isNil or w.writing.finished: w.socket.close
  else: w.writing.addCallback () => w.finish

proc read(w: Wire) {.async.} =
  ## Says each value that arrives into every conversation the wire is
  ## in, until the other end stops sending, resets, or sends bytes that
  ## are not CE, or the wire closes. Bytes left inside a value have
  ## nowhere to go.
  var decoder = newDecoder()
  try:
    while not w.socket.isClosed:
      let data = await w.socket.recv(Chunk, flags = {})
      if data.len == 0: break
      decoder.buf.add data.toBytes
      for view in decoder.checked:
        w.say view.toValue
      decoder.compact
  except CatchableError:
    discard

method left*(w: Wire, r: Room) =
  procCall Speaker(w).left(r)
  callSoon () => w.finish  # so a wire moved from one conversation to another lives

method send*(w: Wire, msg: Msg) =
  ## Writes the value out as CE. Writes on one socket go out whole and in
  ## order, since the dispatcher runs a socket's write callbacks in turn.
  if w.socket.isClosed: raise newException(IOError, "the wire is closed")
  w.writing = w.socket.send(msg.value.ce.toString, flags = {})
  w.writing.addCallback proc(f: Future[void]) =
    if f.failed:
      w.socket.close
      w.leaveAll

proc start(socket: AsyncSocket, r: Room): Wire =
  result = Wire(socket: socket)
  result.join r
  asyncCheck result.read

proc dial*(host: string, port: Port, r: Room): Future[Wire] {.async.} =
  ## connects to `host` and `port`, and joins a wire for it to `r`
  let socket = newAsyncSocket(buffered = false)
  try:
    await socket.connect(host, port)
  except CatchableError:
    socket.close
    raise
  return socket.start(r)

# ================
# Listener
# ================

proc port*(l: Listener): Port =
  l.socket.getLocalAddr[1]

proc close*(l: Listener) =
  ## stops accepting. The wires it joined stay where they are
  if not l.socket.isClosed: l.socket.close

proc accept(l: Listener, r: Room) {.async.} =
  while not l.socket.isClosed:
    var socket: AsyncSocket
    try:
      socket = await l.socket.accept
    except CatchableError:
      if l.socket.isClosed: break
      await sleepAsync(100)  # so a lasting failure doesn't spin
      continue
    if l.socket.isClosed:  # closed while the accept was on its way here
      socket.close
      break
    discard socket.start(r)

proc listen*(port: Port, r: Room, address = ""): Listener =
  ## Listens on `port`, and joins a wire to `r` for each connection.
  ## Sockets are unbuffered, since a buffered recv waits to fill the
  ## whole chunk. Accepted sockets inherit it.
  let socket = newAsyncSocket(buffered = false)
  try:
    socket.setSockOpt(OptReuseAddr, true)
    socket.bindAddr(port, address)
    socket.listen
  except CatchableError:
    socket.close
    raise
  result = Listener(socket: socket)
  asyncCheck result.accept(r)
