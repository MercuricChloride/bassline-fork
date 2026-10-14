## bl ws: the door from a browser's WebSockets to a TCP place

import cli

# ================ ws ================

const WsClient = """
// node wsclient.mjs URL ORIGIN WANT HEX…: each HEX as a binary frame, what happens as JSON
const [url, origin, want, ...sends] = process.argv.slice(2)
const ws = new WebSocket(url, origin ? { headers: { Origin: origin } } : undefined)
ws.binaryType = 'arraybuffer'
const out = []
let got = 0
const done = () => { console.log(JSON.stringify(out)); process.exit(0) }
ws.onopen = () => {
  out.push({ open: true })
  for (const h of sends) ws.send(Buffer.from(h, 'hex'))
  if (+want === 0) setTimeout(() => ws.close(), 300)
}
ws.onmessage = e => {
  out.push({ frame: Buffer.from(e.data).toString('hex') })
  if (++got >= +want) ws.close()
}
ws.onerror = () => out.push({ error: true })
ws.onclose = e => { out.push({ close: e.code }); done() }
setTimeout(() => { out.push({ timeout: true }); done() }, +(process.env.WAIT ?? 5000))
"""

proc wsDoor(behind: Serving, extra: seq[string] = @[]): Serving =
  ## `bl ws :0` carrying to `behind`, once it says where it listens
  result.p = startProcess(bin / "bl", args = @["ws", ":0", "--to", ":" & behind.port] & extra,
                          options = {})
  let said = result.p.errorStream.readLine
  doAssert said.startsWith("-- listening on "), said
  result.place = said["-- listening on ".len .. ^1].split(',')[0]

proc hex(ce: string): string = ce.toHex.toLowerAscii

proc page(door: Serving, origin: string, want: int, sends: seq[string],
          wait = 5000): Process =
  ## a page's WebSocket through `door`, from Node's own client: it sends
  ## each CE string as a binary frame and closes once `want` frames came
  writeFile(tmp / "wsclient.mjs", WsClient)
  putEnv("WAIT", $wait)
  startProcess("node", args = @[tmp / "wsclient.mjs", "ws://" & door.place & "/",
                                origin, $want] & sends.mapIt(hex(it)),
               options = {poUsePath})

proc saw(p: Process): JsonNode =
  ## what the page saw, once it has finished
  result = parseJson(p.outputStream.readAll)
  discard p.waitForExit
  p.close()

proc frames(saw: JsonNode): seq[string] =
  for e in saw: (if e.hasKey("frame"): result.add e["frame"].getStr)

proc opened(saw: JsonNode): bool = saw.getElems.anyIt(it.hasKey("open"))

const RfcKey = "dGhlIHNhbXBsZSBub25jZQ=="   # RFC 6455's own example

proc opening(key = RfcKey, origin = "", version = "13", upgrade = true): string =
  result = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n"
  if upgrade: result.add "Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n"
  result.add "Sec-WebSocket-Key: " & key & "\r\nSec-WebSocket-Version: " & version & "\r\n"
  if origin.len > 0: result.add "Origin: " & origin & "\r\n"
  result.add "\r\n"

type Raw = object
  ## a WebSocket spoken by hand, for what Node's client won't do
  s: Socket
  head, rest: string

proc raw(door: Serving, request = opening()): Raw =
  result.s = newSocket(buffered = false)
  result.s.connect("127.0.0.1", Port(parseInt(door.port)))
  result.s.send(request)
  var got = ""
  while "\r\n\r\n" notin got:
    let more = readFor(cint(result.s.getFd), 65536, 2000)
    if more.len == 0: break
    got.add more
  let cut = got.find("\r\n\r\n")
  result.head = if cut >= 0: got[0 ..< cut] else: got
  result.rest = if cut >= 0: got[cut + 4 .. ^1] else: ""

proc frame(op: int, payload: string, fin = true, mask = true): string =
  ## a frame as a page sends it
  result.add char((if fin: 0x80 else: 0) or op)
  let m = if mask: 0x80 else: 0
  let n = payload.len
  if n < 126: result.add char(m or n)
  elif n <= 0xFFFF:
    result.add char(m or 126)
    result.add char(n shr 8)
    result.add char(n and 0xFF)
  else:
    result.add char(m or 127)
    for i in countdown(7, 0): result.add char((n shr (8 * i)) and 0xFF)
  if mask:
    let key = "\x11\x22\x33\x44"
    result.add key
    for i, c in payload: result.add char(c.byte xor key[i and 3].byte)
  else: result.add payload

proc heard(r: var Raw, ms = 1500): seq[(int, string)] =
  ## the frames the door has sent, as (opcode, payload), until it says
  ## nothing for `ms` or has closed
  var data = r.rest
  r.rest = ""
  while true:
    let more = readFor(cint(r.s.getFd), 1 shl 20, ms)
    if more.len == 0: break
    data.add more
  var i = 0
  while i + 2 <= data.len:
    let op = data[i].int and 0x0F
    var n = data[i + 1].int and 0x7F
    i += 2
    if n == 126:
      n = (data[i].int shl 8) or data[i + 1].int
      i += 2
    elif n == 127:
      n = 0
      for k in 0 .. 7: n = (n shl 8) or data[i + k].int
      i += 8
    if i + n > data.len: break
    result.add (op, data[i ..< i + n])
    i += n

proc closeCode(frames: seq[(int, string)]): int =
  for (op, p) in frames:
    if op == 0x8 and p.len >= 2: return (p[0].int shl 8) or p[1].int
  -1

suite "ws":
  if findExe("node").len == 0:
    echo "  (node isn't on PATH; the page tests need its WebSocket client)"

  test "a page reaches a jam through the door, a value a frame each way":
    let jam = jamServe()
    let door = wsDoor(jam)
    let saw = door.page("http://localhost:5173", 2,
                        @[blb("(general \"hi\") (general)"), blb("(general \"again\")")]).saw
    check saw.frames == @[hex(blb("(general 1 \"hi\")")), hex(blb("(general 2 \"again\")"))]
    check saw[^1]{"close"}.getInt == 1000
    discard door.stop
    discard jam.stop

  test "a message that isn't whole CE isn't carried, and the door carries on":
    let jam = jamServe()
    let door = wsDoor(jam)
    let whole = blb("(general \"cut short\")")
    let saw = door.page("http://localhost:5173", 1,
                        @[whole[0 .. 3], "\xf0", blb("(general \"b\") (general)")]).saw
    check saw.frames == @[hex(blb("(general 1 \"b\")"))]
    let said = door.stop
    check "ends partway through a value, not carried" in said
    check "isn't CE, not carried" in said
    discard jam.stop

  test "an origin that fits no pattern is refused; one that fits, or none, is let in":
    let jam = jamServe()
    let door = wsDoor(jam)
    let evil = door.page("http://evil.example", 1, @[blb("(general \"no\")")]).saw
    check not evil.opened and evil.frames.len == 0
    check door.page("http://127.0.0.1:8080", 0, @[]).saw.opened
    check door.page("", 0, @[]).saw.opened       # a program, not a page
    let said = door.stop
    check "origin http://evil.example isn't allowed" in said
    let only = wsDoor(jam, @["--origin", "http://*.app.test:*", "--origin", "https://app.test"])
    check not only.page("http://localhost:5173", 0, @[]).saw.opened
    check only.page("http://x.app.test:8080", 0, @[]).saw.opened
    check only.page("https://app.test", 0, @[]).saw.opened
    check not only.page("http://a.b.app.test:8080", 0, @[]).saw.opened
    check not only.page("http://x.app.test:8080.evil.com", 0, @[]).saw.opened
    discard only.stop
    discard jam.stop

  test "when the place behind ends the page's WebSocket ends, and when the page goes its line goes":
    var jam = jamServe()
    let door = wsDoor(jam)
    let line = jam.asking(blb("(gone)"))
    discard door.page("http://localhost:5173", 0, @[blb("(here !{(by page) (at 1)})")]).saw
    let gone = line.told
    check gone.len == 1 and gone[0].items[2].answer(sym"by") == some sym"page"
    line.close()
    let waiting = door.page("http://localhost:5173", 5, @[blb("(general)")], wait = 8000)
    sleep 500
    discard jam.stop
    let saw = waiting.saw
    check saw.opened and saw[^1]{"close"}.getInt == 1000
    discard door.stop

  test "the opening: RFC 6455's own key, a plain GET, another version, nothing behind":
    let jam = jamServe()
    let door = wsDoor(jam)
    var r = door.raw()
    check r.head.startsWith("HTTP/1.1 101")
    check "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" in r.head
    r.s.close()
    check door.raw(opening(upgrade = false)).head.startsWith("HTTP/1.1 400")
    let old = door.raw(opening(version = "8")).head
    check old.startsWith("HTTP/1.1 426") and "Sec-WebSocket-Version: 13" in old
    check door.raw(opening(origin = "http://evil.example")).head.startsWith("HTTP/1.1 403")
    let port = jam.port
    discard jam.stop
    check door.raw().head.startsWith("HTTP/1.1 502")
    check "can't reach 127.0.0.1:" & port in door.stop

  test "frames: fragments and a ping between them, and lengths past 125 and 65535":
    let jam = jamServe()
    let door = wsDoor(jam)
    var r = door.raw()
    let msg = blb("(general \"split\") (general)")
    let half = msg.len div 2
    r.s.send(frame(0x2, msg[0 ..< half], fin = false) & frame(0x9, "p") &
             frame(0x0, msg[half .. ^1]))
    check r.heard == @[(0xA, "p"), (0x2, blb("(general 1 \"split\")"))]
    let mid = blb("(general \"" & 'm'.repeat(300) & "\")")
    let big = blb("(general \"" & 'b'.repeat(70_000) & "\")")
    r.s.send(frame(0x2, mid) & frame(0x2, big))
    check r.heard == @[(0x2, blb("(general 2 \"" & 'm'.repeat(300) & "\")")),
                       (0x2, blb("(general 3 \"" & 'b'.repeat(70_000) & "\")"))]
    r.s.send(frame(0x8, "\x03\xe8"))
    check r.heard.closeCode == 1000
    r.s.close()
    discard door.stop
    discard jam.stop

  test "frames: unmasked, text, or past --max-value end the WebSocket, saying why":
    let jam = jamServe()
    let door = wsDoor(jam, @["--max-value", "100"])
    var r = door.raw()
    r.s.send(frame(0x2, blb("(general)"), mask = false))
    check r.heard.closeCode == 1002
    r.s.close()
    r = door.raw()
    r.s.send(frame(0x1, "(general)"))
    check r.heard.closeCode == 1003
    r.s.close()
    r = door.raw()
    r.s.send(frame(0x2, blb("(general \"" & 'x'.repeat(200) & "\")")))
    check r.heard.closeCode == 1009
    r.s.close()
    let said = door.stop
    check "an unmasked frame" in said and "a text frame" in said and "past 100 bytes" in said
    discard jam.stop

  test "a door listens on this machine only":
    for place in ["0.0.0.0:0", "127.lan:0", "[::1]:0"]:
      let r = sh("bl ws " & place)
      check r.code == 2
      check "loopback" in r.errors
    let jam = jamServe()
    let door = startProcess(bin / "bl", args = ["ws", "localhost:0", "--to", ":" & jam.port],
                            options = {})
    check door.errorStream.readLine.startsWith("-- listening on 127.0.0.1:")
    discard kill(Pid(door.processID), SIGTERM)
    discard door.waitForExit
    door.close()
    discard jam.stop

  test "the default origins let in only pages on this machine, over http":
    let jam = jamServe()
    let door = wsDoor(jam)
    proc answered(origin: string): string =
      let r = door.raw(opening(origin = origin))
      r.s.close()
      r.head
    for origin in ["http://localhost.evil.com:5173", "http://127.0.0.1.evil.com:80", "null",
                   "https://localhost:5173", "http://localhost", "http://localhost:5173/x"]:
      check answered(origin).startsWith("HTTP/1.1 403")
    for origin in ["http://localhost:5173", "http://127.0.0.1:8080"]:
      check answered(origin).startsWith("HTTP/1.1 101")
    discard door.stop
    discard jam.stop

  test "a message holding a whole value and then a bad tail carries none of it":
    let jam = jamServe()
    let door = wsDoor(jam)
    var r = door.raw()
    r.s.send(frame(0x2, blb("(general \"first\")") & "\xf0"))
    r.s.send(frame(0x2, blb("(general \"ok\") (general)")))
    check r.heard == @[(0x2, blb("(general 1 \"ok\")"))]   # first never got in
    r.s.close()
    discard door.stop
    discard jam.stop

  test "frames against the protocol end the WebSocket with 1002":
    let jam = jamServe()
    let door = wsDoor(jam)
    proc closesWith(bytes: string): int =
      var r = door.raw()
      r.s.send(bytes)
      result = r.heard.closeCode
      r.s.close()
    let reserved = block:
      var f = frame(0x2, blb("(general)"))
      f[0] = char(f[0].int or 0x40)
      f
    check closesWith(reserved) == 1002
    check closesWith(frame(0x3, "")) == 1002                       # no such opcode
    check closesWith(frame(0x9, 'p'.repeat(126))) == 1002          # a ping past 125
    check closesWith(frame(0x9, "p", fin = false)) == 1002         # a ping in pieces
    check closesWith(frame(0x0, blb("(general)"))) == 1002         # a continuation first
    check closesWith(frame(0x2, "a", fin = false) & frame(0x2, "b")) == 1002   # a new message mid-message
    check closesWith(frame(0x8, "\x03")) == 1002                   # a close of one byte
    check closesWith(frame(0x8, "\x03\xed")) == 1002               # 1005, never sent
    check closesWith(frame(0x8, "\x0f\xa0")) == 4000               # an application's own
    discard door.stop
    discard jam.stop

  test "--max-value bounds a message, a length only claimed holds nothing, and a ping between fragments isn't counted":
    let jam = jamServe()
    let msg = blb("(general \"" & 'x'.repeat(80) & "\") (general)")
    let door = wsDoor(jam, @["--max-value", $(msg.len + 5)])
    var r = door.raw()
    r.s.send(frame(0x2, msg[0 ..< msg.len - 2], fin = false) & frame(0x9, 'p'.repeat(20)) &
             frame(0x0, msg[msg.len - 2 .. ^1]))
    check r.heard == @[(0xA, 'p'.repeat(20)), (0x2, blb("(general 1 \"" & 'x'.repeat(80) & "\")"))]
    r.s.close()
    r = door.raw()
    r.s.send("\x82\xff\x00\x00\x01\x00\x00\x00\x00\x00")    # claims 2^40 bytes
    check r.heard.closeCode == 1009
    r.s.close()
    discard door.stop
    discard jam.stop

  test "connections reset as they are accepted leave nothing open":
    let jam = jamServe()
    let door = wsDoor(jam)
    proc sockets(): int =
      let r = execCmdEx("lsof -nP -a -p " & $door.p.processID & " -i")
      max(0, r.output.strip.splitLines.len - 1)
    let before = sockets()
    for _ in 0 ..< 100:
      let s = newSocket(buffered = false)
      s.connect("127.0.0.1", Port(parseInt(door.port)))
      var linger = TLinger(l_onoff: 1, l_linger: 0)
      discard setsockopt(s.getFd, SOL_SOCKET, SO_LINGER, addr linger, SockLen(sizeof(linger)))
      s.close()
    sleep 1000
    check sockets() <= before
    check door.page("http://localhost:5173", 0, @[]).saw.opened
    discard door.stop
    discard jam.stop

  test "a place behind that takes in nothing holds the door to a window, and is ended after --stall":
    let stuck = newSocket()
    stuck.setSockOpt(OptReuseAddr, true)
    stuck.bindAddr(Port(0), "127.0.0.1")
    stuck.listen()
    let behind = Serving(place: "127.0.0.1:" & $int(stuck.getLocalAddr()[1]))
    let door = wsDoor(behind, @["--stall", "1"])
    var r = door.raw()
    var taken: Socket
    stuck.accept(taken)                          # and never read
    let big = frame(0x2, blb("(general \"" & 'x'.repeat(1 shl 20) & "\")"))
    for _ in 0 ..< 40:
      try: r.s.send(big, flags = {})            # raising, not spinning, once the door has gone
      except CatchableError: break
    check r.heard(3000).closeCode == 1011
    let rss = execCmdEx("ps -o rss= -p " & $door.p.processID).output.strip.parseInt
    check rss < 100_000                          # in KB: a window, not 40 MB
    r.s.close()
    let said = door.stop
    check "takes in nothing" in said
    taken.close()
    stuck.close()

  test "a page that takes in nothing is ended once a window waits for it":
    let jam = jamServe()
    for i in 0 ..< 20:
      check jam.put(blb("(general \"" & 'y'.repeat(1 shl 20) & $i & "\")")).code == 0
    let door = wsDoor(jam, @["--stall", "1"])
    var r = door.raw()
    r.s.send(frame(0x2, blb("(general)")))       # and never read
    sleep 3000
    let said = door.stop
    check "the page takes in nothing" in said
    r.s.close()
    discard jam.stop
