## the landing surface: values in, replies out, over a socket

import std/[unittest, asyncdispatch, asyncnet, nativesockets]
from std/strutils import repeat
import bl/core
import bl/lib/[blmacro, server]

proc within(fut: Future[void], ms = 5000) =
  doAssert waitFor withTimeout(fut, ms), "timed out"

proc blob(vs: openArray[Value]): seq[byte] =
  for v in vs: result.add ce(v)

proc drip(sock: AsyncSocket, bytes: seq[byte], step: int) {.async.} =
  ## feed the wire in `step`-sized bites, with no regard for value edges
  var i = 0
  while i < bytes.len:
    let stop = min(i + step, bytes.len)
    await sock.send(toString(bytes.toOpenArray(i, stop - 1)))
    await sleepAsync(1)
    i = stop

suite "landing surface":
  test "values land in order across awkward chunk splits":
    var landed: seq[Value]
    proc onValue(conn: Conn, m: Msg): Future[void] {.async.} =
      landed.add m.value
    let l = newLanding(Port(0), onValue)
    asyncCheck l.serve()

    let corpus = @[bl(1), bl "two", bl(!add(1, 2)), bl [],
                   bl {3, 2}, bl {k: nil}]
    proc run() {.async.} =
      let sock = newAsyncSocket(buffered = false)
      await sock.connect("127.0.0.1", l.port)
      await sock.drip(corpus.blob, 7)
      while landed.len < corpus.len: await sleepAsync(5)
      sock.close()
    within run()
    check landed == corpus
    l.close()

  test "a value larger than one recv chunk":
    var landed: seq[Value]
    proc onValue(conn: Conn, m: Msg): Future[void] {.async.} =
      landed.add m.value
    let l = newLanding(Port(0), onValue)
    asyncCheck l.serve()

    let big = text('e'.repeat(70_000))
    proc run() {.async.} =
      let c = await connect("127.0.0.1", l.port)
      await c.send(big)
      while landed.len < 1: await sleepAsync(5)
      c.close()
    within run()
    check landed == @[big]
    l.close()

  test "a handler sends a reply back on the same connection":
    proc onValue(conn: Conn, m: Msg): Future[void] {.async.} =
      discard m.reply(bl(landed(%m.value)))
    let l = newLanding(Port(0), onValue)
    asyncCheck l.serve()

    var back: Value
    var got = false
    proc run() {.async.} =
      let c = await connect("127.0.0.1", l.port)
      asyncCheck c.pump(proc(v: Value) {.async.} =
        back = v
        got = true)
      await c.send(bl(!quote("hello", {1, 2})))
      while not got: await sleepAsync(5)
      c.close()
    within run()
    check back == bl(landed(!quote("hello", {1, 2})))
    l.close()

  test "malformed input closes that connection":
    var closed = false
    var codecErr = false
    proc onValue(conn: Conn, m: Msg): Future[void] {.async.} = discard
    proc onClose(conn: Conn) = closed = true
    proc onError(conn: Conn, e: ref Exception) = codecErr = e of CodecError
    let l = newLanding(Port(0), onValue, onClose = onClose, onError = onError)
    asyncCheck l.serve()

    proc run() {.async.} =
      let sock = newAsyncSocket(buffered = false)
      await sock.connect("127.0.0.1", l.port)
      await sock.send("\x00")            # tag 0: the decoder must crash
      discard await sock.recv(64)        # returns when the server hangs up
      while not closed: await sleepAsync(5)
      sock.close()
    within run()
    check closed
    check codecErr
    l.close()

  test "a handler bug closes only its own connection":
    var landed: seq[Value]
    var bugs = 0
    proc onValue(conn: Conn, m: Msg): Future[void] {.async.} =
      if m.value == bl(boom):
        var xs: seq[int]
        discard xs[3]                    # IndexDefect from app code
      landed.add m.value
    proc onError(conn: Conn, e: ref Exception) = inc bugs
    let l = newLanding(Port(0), onValue, onError = onError)
    asyncCheck l.serve()

    proc run() {.async.} =
      let c1 = await connect("127.0.0.1", l.port)
      await c1.send(bl(boom))
      let c2 = await connect("127.0.0.1", l.port)
      await c2.send(bl(fine))
      while landed.len < 1: await sleepAsync(5)
      c1.close()
      c2.close()
    within run()
    check bugs == 1
    check landed == @[bl(fine)]
    l.close()
