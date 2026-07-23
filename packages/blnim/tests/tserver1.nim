import std/unittest
import std/options
from std/strutils import repeat
import pkg/core
import pkg/lib/[server]

suite "landing surface":
  test "values land in order across awkward splits":
    var landed: seq[Value]
    proc onV(conn: Conn, v: Value) {.async.} =
      landed.add v

    let l = landing(Port(0), onV)
    asyncCheck l.serve()
    try:
      let corpus = @[
        num"1",
        text"two",
        mark(record(sym"add", num"1", num"2")),
        list(),
        set(num"3", num"2"),
        dict(@[(sym"k", nilValue())]),
      ]
      var bytes: seq[byte]
      for v in corpus:
        bytes.add encode(v)

      proc run() {.async.} =
        # a raw client, dripping bytes with no regard for value boundaries
        let sock = newAsyncSocket(buffered = false)
        await sock.connect("127.0.0.1", l.localPort)
        var i = 0
        while i < bytes.len:
          let stop = min(i + 7, bytes.len)
          var chunk = newString(stop - i)
          copyMem(addr chunk[0], addr bytes[i], stop - i)
          await sock.send(chunk)
          await sleepAsync(1)
          i = stop
        while landed.len < corpus.len:
          await sleepAsync(5)
        sock.close()

      check waitFor withTimeout(run(), 10_000)
      check landed == corpus
    finally:
      l.close()

  test "a value larger than one recv chunk":
    var landed: seq[Value]
    proc onV(conn: Conn, v: Value) {.async.} =
      landed.add v

    let l = landing(Port(0), onV)
    asyncCheck l.serve()
    try:
      let big = text(repeat('e', 70_000))
      proc run() {.async.} =
        let c = await connect("127.0.0.1", l.localPort)
        await c.send(big)
        while landed.len < 1:
          await sleepAsync(5)
        c.close()

      check waitFor withTimeout(run(), 10_000)
      check landed == @[big]
    finally:
      l.close()

  test "a handler can speak back":
    proc onV(conn: Conn, v: Value) {.async.} =
      await conn.send(record(sym"landed", v))

    let l = landing(Port(0), onV)
    asyncCheck l.serve()
    try:
      proc run(): Future[bool] {.async.} =
        let c = await connect("127.0.0.1", l.localPort)
        let v = mark(record(sym"quote", text"hello", set(num"1", num"2")))
        await c.send(v)
        let back = await c.receive()
        c.close()
        return back.isSome and back.get == record(sym"landed", v)

      let fut = run()
      check waitFor withTimeout(fut, 10_000)
      check fut.read()
    finally:
      l.close()

  test "malformed input closes the connection":
    var sawClose = false
    var sawDecodeError = false
    proc onV(conn: Conn, v: Value) {.async.} =
      discard

    proc onCl(conn: Conn) =
      sawClose = true

    proc onEr(conn: Conn, e: ref Exception) =
      sawDecodeError = e of DecodeError

    let l = landing(Port(0), onV, onClose = onCl, onError = onEr)
    asyncCheck l.serve()
    try:
      proc run() {.async.} =
        let sock = newAsyncSocket(buffered = false)
        await sock.connect("127.0.0.1", l.localPort)
        await sock.send("\x00") # invalid tag
        discard await sock.recv(1024) # completes when the server closes
        while not sawClose:
          await sleepAsync(5)
        sock.close()

      check waitFor withTimeout(run(), 10_000)
      check sawClose
      check sawDecodeError
    finally:
      l.close()

  test "a handler bug closes only its own connection":
    var landed: seq[Value]
    proc onV(conn: Conn, v: Value) {.async.} =
      if v == sym"boom":
        var empty: seq[int]
        discard empty[3] # IndexDefect: a bug in app code
      landed.add v

    let l = landing(Port(0), onV)
    asyncCheck l.serve()
    try:
      proc run() {.async.} =
        let c1 = await connect("127.0.0.1", l.localPort)
        await c1.send(sym"boom")
        # the surface closes c1; the landing must survive to serve c2
        let c2 = await connect("127.0.0.1", l.localPort)
        await c2.send(sym"fine")
        while landed.len < 1:
          await sleepAsync(5)
        c1.close()
        c2.close()

      check waitFor withTimeout(run(), 10_000)
      check landed == @[sym"fine"]
    finally:
      l.close()
