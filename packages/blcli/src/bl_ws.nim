## bl ws: a door between WebSockets and a TCP place
##
## A browser can't dial TCP, so a page reaches a jam, or anything that
## speaks bare CE over TCP, through this door. Each WebSocket that opens
## here gets its own TCP connection to the place behind the door, and the
## door carries CE between them: each value that arrives over TCP goes
## out as one binary frame, and each binary message that arrives goes on
## as the run of values it holds, byte for byte. The door reads no
## meanings, and nothing about either connection reaches the values.
## When either side ends, the door ends the other: its own decision,
## said in no value.

import std/[base64, net, sequtils, strutils, tables, sugar]
import checksums/sha1
import harness
import bl/core
import bl/lib/server

const
  DoorPlace = "127.0.0.1:8457"
  BehindPlace = "127.0.0.1:8456"   ## a jam, by default
  DefaultOrigins = ["http://localhost:*", "http://127.0.0.1:*"]
  Guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    ## RFC 6455's, which the opening's answer hashes with the key
  MaxHead = 16 * 1024   ## the most an opening request may take
  Window = 16 * 1024 * 1024
    ## the most the door holds for either side before it waits on it
  Piece = 64 * 1024     ## how much of a frame to read at once

  OpContinue = 0x0
  OpText = 0x1
  OpBinary = 0x2
  OpClose = 0x8
  OpPing = 0x9
  OpPong = 0xA

  Normal = 1000
  ProtocolError = 1002
  Unsupported = 1003
  Policy = 1008
  TooBig = 1009
  Unexpected = 1011

type
  Door = ref object
    behind: Place
    origins: seq[string]
    maxValue: int
    stall: int     ## how long, in ms, to wait on a side that takes in nothing

  Ws = ref object
    ## the WebSocket half of one carrying
    socket: AsyncSocket
    address: string
    stall: int
    lastWrite: Future[void]
    queued: int    ## bytes handed to the socket and not yet gone
    ending: bool   ## a close has gone out, or a write failed

# ================ the opening ================

proc fits*(origin, pattern: string): bool =
  ## whether an origin fits a pattern, where * stands for a run of one or
  ## more characters with no `.`, `/` or `:` in it: a port, or one label
  ## of a name. Letters match whatever their case
  if pattern.len == 0: return origin.len == 0
  if pattern[0] == '*':
    var run = 0
    while run < origin.len and origin[run] notin {'.', '/', ':'}: inc run
    for i in countdown(run, 1):
      if fits(origin[i .. ^1], pattern[1 .. ^1]): return true
    return false
  origin.len > 0 and origin[0].toLowerAscii == pattern[0].toLowerAscii and
    fits(origin[1 .. ^1], pattern[1 .. ^1])

proc acceptOf*(key: string): string =
  ## the answer to an opening's key
  base64.encode(Sha1Digest(secureHash(key & Guid)))

proc answer(client: AsyncSocket, status: string, headers = "") {.async.} =
  try:
    await client.send("HTTP/1.1 " & status & "\r\n" & headers &
                      "Content-Length: 0\r\nConnection: close\r\n\r\n")
  except CatchableError: discard

proc opening(d: Door, client: AsyncSocket, address: string): Future[string] {.async.} =
  ## reads the request that opens a WebSocket, answering its key, or ""
  ## once it has been refused and told why
  proc refuse(status, why: string, headers = "") {.async.} =
    chatter "refused " & address & ": " & why
    await client.answer(status, headers)
  var
    lines: seq[string]
    size = 0
  while true:
    let line = await client.recvLine(maxLength = MaxHead)
    if line.len == 0: return ""   # gone before it finished asking
    if line == "\c\L": break
    size += line.len
    if size > MaxHead:
      await refuse("431 Request Header Fields Too Large", "an opening past " & $MaxHead & " bytes")
      return ""
    lines.add line
  if lines.len == 0 or not lines[0].startsWith("GET ") or
     not lines[0].contains(" HTTP/1."):
    await refuse("400 Bad Request", "not a GET")
    return ""
  var headers: Table[string, string]
  for line in lines[1 .. ^1]:
    let colon = line.find(':')
    if colon > 0: headers[line[0 ..< colon].strip.toLowerAscii] = line[colon + 1 .. ^1].strip
  let tokens = headers.getOrDefault("connection").toLowerAscii.split(',')
  if headers.getOrDefault("upgrade").toLowerAscii != "websocket" or
     not tokens.anyIt(it.strip == "upgrade"):
    await refuse("400 Bad Request", "not a WebSocket opening")
    return ""
  if headers.getOrDefault("sec-websocket-version") != "13":
    await refuse("426 Upgrade Required", "WebSocket version " &
                 headers.getOrDefault("sec-websocket-version") & ", not 13",
                 "Sec-WebSocket-Version: 13\r\n")
    return ""
  if "origin" in headers and not d.origins.anyIt(fits(headers["origin"], it)):
    await refuse("403 Forbidden", "origin " & headers["origin"] & " isn't allowed")
    return ""
  let key = headers.getOrDefault("sec-websocket-key")
  if key.len == 0:
    await refuse("400 Bad Request", "no Sec-WebSocket-Key")
    return ""
  key

# ================ frames ================

proc frame(op: int, payload: openArray[byte]): string =
  ## a frame from this side, whole and unmasked
  result = newStringOfCap(payload.len + 10)
  result.add char(0x80 or op)
  let n = payload.len
  if n < 126:
    result.add char(n)
  elif n <= 0xFFFF:
    result.add char(126)
    result.add char(n shr 8)
    result.add char(n and 0xFF)
  else:
    result.add char(127)
    for i in countdown(7, 0): result.add char((n shr (8 * i)) and 0xFF)
  for b in payload: result.add char(b)

proc transmit(ws: Ws, data: string) {.async.} =
  ws.queued += data.len
  try: await ws.socket.send(data)
  except CatchableError: ws.ending = true
  ws.queued -= data.len

proc finish(ws: Ws, code: int) {.async.} =
  ## ends the WebSocket: a close with `code`, once what is queued has
  ## gone or the page has taken in nothing for the stall, then the socket
  if not ws.ending and not ws.socket.isClosed:
    ws.lastWrite = ws.transmit(frame(OpClose, [byte(code shr 8), byte(code and 0xFF)]))
    ws.ending = true
  if ws.lastWrite != nil: discard await ws.lastWrite.withTimeout(ws.stall)
  if not ws.socket.isClosed: ws.socket.close()

proc send(ws: Ws, op: int, payload: openArray[byte]): bool =
  ## queues a frame, answering whether it was taken for sending. A page
  ## that takes in nothing while a window's worth waits for it is ended
  if ws.ending or ws.socket.isClosed: return false
  if ws.queued > 0 and ws.queued + payload.len > Window:
    chatter "failed " & ws.address & ": the page takes in nothing, with " &
      $ws.queued & " bytes held for it"
    asyncCheck ws.finish(Policy)
    return false
  ws.lastWrite = ws.transmit(frame(op, payload))
  true

proc take(ws: Ws, n: int): Future[string] {.async.} =
  ## the next `n` bytes, or fewer once the other end has gone, a piece at
  ## a time, so a length a frame only claims holds no memory
  while result.len < n:
    var piece = ""
    try: piece = await ws.socket.recv(min(n - result.len, Piece))
    except CatchableError: discard
    if piece.len == 0: return
    result.add piece

proc carry(ws: Ws, conn: Conn, message: string, maxValue: int): int =
  ## hands on the values a message holds, if it holds whole ones, byte
  ## for byte, answering how many bytes went on, or -1 once the TCP side
  ## takes no more
  var d = newDecoder(maxValueBytes = maxValue)
  d.buf.add message.toBytes
  try:
    for _ in d.checked: discard
  except CodecError as e:
    chatter "malformed " & ws.address & ": a message that isn't CE, not carried (" & e.msg & ")"
    return 0
  if d.pending:
    chatter "malformed " & ws.address & ": a message that ends partway through a value, not carried"
    return 0
  if message.len == 0: return 0
  if conn.write(message.toOpenArrayByte(0, message.high)): message.len else: -1

proc inward(d: Door, ws: Ws, conn: Conn) {.async.} =
  ## carries what the WebSocket says to the TCP side until it ends
  var
    message = ""        # a binary message gathered from its fragments
    gathering = false
    held = 0            # bytes handed to the TCP side since it last caught up
  proc broken(why: string, code = ProtocolError) {.async.} =
    chatter "malformed " & ws.address & ": " & why
    await ws.finish(code)
  while not ws.socket.isClosed:
    let head = await ws.take(2)
    if head.len < 2: return
    let (b0, b1) = (head[0].int, head[1].int)
    let fin = (b0 and 0x80) != 0
    let op = b0 and 0x0F
    if (b0 and 0x70) != 0:
      await broken("a frame with reserved bits set")
      return
    if (b1 and 0x80) == 0:
      await broken("an unmasked frame")
      return
    var n = b1 and 0x7F
    if n == 126:
      let e = await ws.take(2)
      if e.len < 2: return
      n = (e[0].int shl 8) or e[1].int
    elif n == 127:
      let e = await ws.take(8)
      if e.len < 8: return
      var big: uint64
      for c in e: big = (big shl 8) or c.uint64
      if big > uint64(d.maxValue):
        await broken("a frame past " & $d.maxValue & " bytes", TooBig)
        return
      n = int(big)
    if op >= OpClose and (not fin or n > 125):
      await broken("a control frame fragmented or past 125 bytes")
      return
    if op < OpClose and message.len + n > d.maxValue:
      await broken("a message past " & $d.maxValue & " bytes", TooBig)
      return
    let mask = await ws.take(4)
    if mask.len < 4: return
    var payload = await ws.take(n)
    if payload.len < n: return
    for i in 0 ..< payload.len:
      payload[i] = char(payload[i].byte xor mask[i and 3].byte)
    case op
    of OpBinary, OpContinue:
      if (op == OpBinary) == gathering:
        await broken("a fragment out of turn")
        return
      message.add payload
      gathering = not fin
      if fin:
        let carried = ws.carry(conn, message, d.maxValue)
        if carried < 0: return
        message = ""
        held += carried
        if held > Window:   # wait for the place behind to take it in
          if not await conn.flush().withTimeout(d.stall):
            chatter "failed " & ws.address & ": " & $d.behind & " takes in nothing, with " &
              $held & " bytes held for it"
            await ws.finish(Unexpected)
            return
          held = 0
    of OpText:
      chatter "refused " & ws.address & ": a text frame; values go in binary frames"
      await ws.finish(Unsupported)
      return
    of OpClose:
      let code =
        if payload.len == 0: Normal
        elif payload.len == 1: ProtocolError
        else:
          let c = (payload[0].int shl 8) or payload[1].int
          if c in 1000 .. 1003 or c in 1007 .. 1011 or c in 3000 .. 4999: c
          else: ProtocolError
      await ws.finish(code)
      return
    of OpPing:
      discard ws.send(OpPong, payload.toOpenArrayByte(0, payload.high))
    of OpPong: discard
    else:
      await broken("opcode " & $op)
      return

# ================ carrying ================

proc door(d: Door, client: AsyncSocket, address: string) {.async.} =
  ## one WebSocket, carried to its own TCP connection until either ends
  var conn: Conn
  try:
    let key = await d.opening(client, address)
    if key.len == 0:
      client.close()
      return
    proc behind(e: EdgeEvent) =
      if e.kind in {edgeTruncated, edgeMalformed, edgeFailed}:
        chatter $e.kind & " " & address & " (behind, " & $d.behind & ")" &
          (if e.error != nil: ": " & e.error.msg else: "")
    try:
      conn = await connect(d.behind.host, d.behind.port, behind, d.maxValue)
    except CatchableError as e:
      chatter "failed " & address & ": can't reach " & $d.behind & " (" & e.msg & ")"
      await client.answer("502 Bad Gateway")
      client.close()
      return
    await client.send("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" &
                      "Connection: Upgrade\r\nSec-WebSocket-Accept: " & acceptOf(key) &
                      "\r\n\r\n")
    chatter "open " & address
    let ws = Ws(socket: client, address: address, stall: d.stall)
    let outward = conn.pump((ce: openArray[byte]) => ws.send(OpBinary, ce))
    outward.addCallback(() => asyncCheck(ws.finish(Normal)))
    await d.inward(ws, conn)
    discard await conn.flush().withTimeout(d.stall)
    conn.close()
    await ws.finish(Normal)
    chatter "close " & address
  except CatchableError as e:
    chatter "failed " & address & ": " & e.msg
    if conn != nil: conn.close()
    if not client.isClosed: client.close()

proc loopback(host: string): string =
  ## the IPv4 loopback address `host` spells (localhost is 127.0.0.1), or
  ## "": a name is not resolved, so it can't lead anywhere else
  let h = if host == "localhost": "127.0.0.1" else: host
  try:
    let ip = parseIpAddress(h)
    if ip.family == IpAddressFamily.IPv4 and ip.address_v4[0] == 127: return h
  except ValueError: discard
  ""

proc run(t: Tool, a: Args) =
  if a.positional.len > 1:
    t.misuse "takes one place at most"
  let spelled = if a.positional.len == 1: a.positional[0] else: DoorPlace
  let place =
    try: parsePlace(spelled, allowZero = true)
    except ValueError as e: t.misuse e.msg
  let host = if place.kind == tcpPlace: loopback(place.host) else: ""
  if host.len == 0:
    t.misuse "a door is for this machine: it listens on an IPv4 loopback address " &
      "(127.x.x.x, or localhost), not " & spelled
  let behind =
    try: parsePlace(a.get("to", BehindPlace))
    except ValueError as e: t.misuse e.msg
  if behind.kind != tcpPlace:
    t.misuse "--to is a TCP place"
  let maxValue = t.intOpt(a, "max-value", MaxValueBytes, lo = 1)
  let stall = t.intOpt(a, "stall", 30, lo = 1)
  let origins = if a.has("origin"): a.every("origin") else: @DefaultOrigins
  let d = Door(behind: behind, origins: origins, maxValue: maxValue, stall: stall * 1000)

  # buffered, unlike server.nim's sockets: the accepted sockets inherit
  # it, and take relies on a buffered recv waiting for all it asks for
  let server = newAsyncSocket(buffered = true)
  try:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(place.port, host)
    server.listen()
  except CatchableError as e:
    fail "can't listen on " & $place & ": " & e.msg
  chatter "listening on " & $Place(kind: tcpPlace, host: host,
                                   port: server.getLocalAddr()[1]) &
    ", carrying to " & $behind & ", for origins " & origins.join(" ")
  proc accepting() {.async.} =
    while true:
      var client: AsyncSocket
      try: client = await server.accept()
      except CatchableError as e:
        chatter "failed to accept: " & e.msg
        await sleepAsync(100)   # a listener that stays readable doesn't spin
        continue
      var address = "a page gone at once"   # door closes it when it reads nothing
      try:
        let (h, p) = client.getPeerAddr()
        address = h & ":" & $int(p)
      except CatchableError: discard
      asyncCheck d.door(client, address)
  waitFor accepting()

let tool* = Tool(
  name: "ws",
  args: "[PLACE]",
  summary: "a door from WebSockets to a TCP place, for pages in a browser",
  about: """
PLACE is where it listens, on this machine only (default """ & DoorPlace & """).
Each WebSocket that opens gets its own TCP connection to the place
behind the door (--to, default """ & BehindPlace & """, a jam; :8455 is
where bl serve and the Mac app listen). Each value that arrives over
TCP goes out as one binary frame; each binary message that arrives goes
on as the values it holds, byte for byte, and one that isn't whole CE
is not carried. Text frames are refused. When either side ends, the
door ends the other. The door holds at most 16 MB for either side
before it waits on it, and a side that takes in nothing for --stall
seconds while the door holds something for it is ended, with the
other.

An opening whose Origin fits none of the --origin patterns is refused,
so other pages open in the browser can't reach what is behind the
door. A * in a pattern stands for a port, or one label of a name. An
opening with no Origin, from a program rather than a page, is let in;
a program on this machine could dial the place behind the door anyway.
No subprotocols or extensions are taken up.

What happens goes to stderr, one line each: open, close, refused,
malformed, failed.""",
  opts: @[Opt(long: "to", arg: "PLACE",
              help: "the TCP place behind the door (default " & BehindPlace & ")"),
          Opt(long: "origin", arg: "PATTERN",
              help: "a page origin to let in; may be given again " &
                    "(default " & DefaultOrigins.join(" and ") & ")"),
          Opt(long: "max-value", arg: "BYTES",
              help: "the most a message or a value may hold, either way " &
                    "(default " & $MaxValueBytes & ")"),
          Opt(long: "stall", arg: "SECONDS",
              help: "how long to wait on a side that takes in nothing (default 30)")],
  run: run)
