import std/unittest
import std/[options, os, tempfiles, nativesockets, posix]
from std/strutils import repeat
import pkg/core
import pkg/lib/[server]

proc pathThere(p: string): bool =
  # fileExists is regular-files-only; a socket needs lstat
  var st: Stat
  lstat(p.cstring, st) == 0

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

suite "unix landings":
  test "values land through a unix socket; close removes it":
    let dir = createTempDir("blsock", "")
    let path = dir / "place"
    var landed: seq[Value]
    proc onV(conn: Conn, v: Value) {.async.} =
      landed.add v

    let l = landingUnix(path, onV)
    asyncCheck l.serve()
    proc run() {.async.} =
      let c = await connectUnix(path)
      await c.send(num"7")
      await c.send(text"eight")
      while landed.len < 2:
        await sleepAsync(5)
      c.close()

    check waitFor withTimeout(run(), 10_000)
    check landed == @[num"7", text"eight"]
    check pathThere(path)
    l.close()
    check not pathThere(path)
    removeDir(dir)

  test "a stale socket is claimed; anything else is refused":
    let dir = createTempDir("blsock", "")
    proc onV(conn: Conn, v: Value) {.async.} =
      discard

    # a crash leaves the socket file with nobody behind it
    let stale = dir / "stale"
    block:
      let s = newAsyncSocket(
        nativesockets.AF_UNIX, nativesockets.SOCK_STREAM, nativesockets.IPPROTO_IP,
        buffered = false,
      )
      bindUnix(s, stale)
      s.close() # no removeFile: the leftover a crash would leave
    check pathThere(stale)
    let l = landingUnix(stale, onV) # claims it
    l.close()
    check not pathThere(stale)

    # a live landing refuses a second one on the same path
    let busy = dir / "busy"
    let l1 = landingUnix(busy, onV)
    asyncCheck l1.serve()
    expect OSError:
      discard landingUnix(busy, onV)
    l1.close()

    # a regular file is never unlinked just because the name is wanted
    let f = dir / "occupied"
    writeFile(f, "not a socket")
    expect OSError:
      discard landingUnix(f, onV)
    check readFile(f) == "not a socket"
    removeDir(dir)
