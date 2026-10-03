## a listener on a real TCP socket: values that arrive go to a local
## send; an outward send writes CE that a listener receives

import std/[unittest, asyncdispatch, asyncnet, nativesockets, posix, sequtils]
from std/strutils import repeat
import bl/core
import bl/lib/[blmacro, server]

template listen(send: untyped, observe: Observer = nil): Listener =
  newListener(Port(0), send, observe, "127.0.0.1")

proc dial(l: Listener, observe: Observer = nil): Future[Conn] =
  connect("127.0.0.1", l.port, observe)

proc within(fut: Future[void], ms = 5000) =
  doAssert waitFor withTimeout(fut, ms), "timed out"

proc waitUntil(cond: proc(): bool) {.async.} =
  while not cond(): await sleepAsync(2)

proc settle() =
  ## let the callbacks of closed connections run before the next test
  waitFor sleepAsync(10)

proc blob(vs: openArray[Value]): seq[byte] =
  for v in vs: result.add ce(v)

proc drip(c: Conn, bytes: seq[byte], step: int) {.async.} =
  ## feed the wire in `step`-sized bites, with no regard for value edges
  var i = 0
  while i < bytes.len:
    let stop = min(i + step, bytes.len)
    doAssert c.write(bytes.toOpenArray(i, stop - 1))
    await c.flush()
    await sleepAsync(1)
    i = stop

func kinds(es: seq[EdgeEvent]): seq[EdgeKind] =
  es.mapIt(it.kind)

func count(es: seq[EdgeEvent], k: EdgeKind): int =
  es.countIt(it.kind == k)

let corpus = @[bl(1), bl "two", bl(!add(1, 2)), bl(!go), bl(!42), bl [],
               bl {3, 2}, bl {k: nil}, bl(!{7}), bl x"dead_beef",
               bl(n"123456789012345678901234567890"),
               bl(n"-98765432109876543210"),
               bl(quote(!"hello", [n"18446744073709551616"]))]

suite "listener":
  test "values arrive in order and intact across awkward chunk splits":
    var arrived: seq[Value]
    proc onValue(v: Value): bool =
      arrived.add v
      true
    let l = listen(onValue)
    asyncCheck l.serve()
    proc run() {.async.} =
      let c = await dial(l)
      await c.drip(corpus.blob, 7)
      await waitUntil(proc(): bool = arrived.len >= corpus.len)
      c.close()
    within run()
    check arrived == corpus
    l.close()
    settle()

  test "the outward send delivers CE that a listener receives":
    var arrived: seq[Value]
    proc onValue(v: Value): bool =
      arrived.add v
      true
    let l = listen(onValue)
    asyncCheck l.serve()
    let big = text('e'.repeat(70_000)) # past one recv chunk
    var refused = false
    proc run() {.async.} =
      let c = await dial(l)
      let send = c.sender
      for v in corpus & big:
        doAssert send(v)
      await waitUntil(proc(): bool = arrived.len >= corpus.len + 1)
      c.close()
      refused = not send(bl late)
    within run()
    check arrived == corpus & big
    check refused
    l.close()
    settle()

  test "a listener for relays hands on each value's CE unbuilt":
    var arrived: seq[seq[byte]]
    proc onCe(ce: openArray[byte]): bool =
      arrived.add @ce
      true
    let l = listen(onCe)
    asyncCheck l.serve()
    proc run() {.async.} =
      let c = await dial(l)
      await c.drip(corpus.blob, 5)
      await waitUntil(proc(): bool = arrived.len >= corpus.len)
      c.close()
    within run()
    check arrived == corpus.mapIt(ce(it))
    l.close()
    settle()

  test "a connection closed partway through a value is reported":
    var arrived: seq[Value]
    var events: seq[EdgeEvent]
    proc onValue(v: Value): bool =
      arrived.add v
      true
    proc observe(e: EdgeEvent) = events.add e
    let l = listen(onValue, observe)
    asyncCheck l.serve()
    let whole = bl(first)
    let half = ce(bl(second(1, 2, 3)))
    proc run() {.async.} =
      let c = await dial(l)
      doAssert c.write(whole)
      doAssert c.write(half.toOpenArray(0, half.len div 2))
      await c.flush()
      await waitUntil(proc(): bool = arrived.len >= 1)
      c.close()
      await waitUntil(proc(): bool = events.count(edgeClose) >= 1)
    within run()
    check arrived == @[whole]
    check events.kinds == @[edgeOpen, edgeTruncated, edgeClose]
    check events.allIt(it.address.len > 0)
    check $events[1] == "truncated " & events[1].address
    l.close()
    settle()

  test "a malformed byte closes only that connection":
    var arrived: seq[Value]
    var events: seq[EdgeEvent]
    proc onValue(v: Value): bool =
      arrived.add v
      true
    proc observe(e: EdgeEvent) = events.add e
    let l = listen(onValue, observe)
    asyncCheck l.serve()
    var goodHeard = true
    proc run() {.async.} =
      let bad = await dial(l)
      let good = await dial(l)
      # a client pump ends when the listener hangs up on it
      let badHungUp = bad.pump(proc(v: Value): bool = true)
      let goodHungUp = good.pump(proc(v: Value): bool = true)
      doAssert good.write(bl(before))
      doAssert bad.write([0'u8]) # tag 0: the decoder must refuse
      await badHungUp
      doAssert good.write(bl(after))
      await waitUntil(proc(): bool = arrived.len >= 2)
      goodHeard = not goodHungUp.finished
      bad.close()
      good.close()
    within run()
    check goodHeard
    check arrived == @[bl(before), bl(after)]
    check events.count(edgeMalformed) == 1
    check events.filterIt(it.kind == edgeMalformed)[0].error of CodecError
    l.close()
    settle()

  test "a send that raises closes only its own connection":
    var arrived: seq[Value]
    var events: seq[EdgeEvent]
    proc onValue(v: Value): bool =
      if v == bl(boom):
        var xs: seq[int]
        discard xs[3] # IndexDefect from app code
      arrived.add v
      true
    proc observe(e: EdgeEvent) = events.add e
    let l = listen(onValue, observe)
    asyncCheck l.serve()
    proc run() {.async.} =
      let c1 = await dial(l)
      let c2 = await dial(l)
      let hungUp = c1.pump(proc(v: Value): bool = true)
      doAssert c1.write(bl(boom))
      await hungUp
      doAssert c2.write(bl(fine))
      await waitUntil(proc(): bool = arrived.len >= 1)
      c1.close()
      c2.close()
    within run()
    check events.count(edgeFailed) == 1
    check arrived == @[bl(fine)]
    l.close()
    settle()

  test "closing a listener closes the connections it accepted":
    var events: seq[EdgeEvent]
    proc observe(e: EdgeEvent) = events.add e
    let l = listen(proc(v: Value): bool = true, observe)
    asyncCheck l.serve()
    proc run() {.async.} =
      let c = await dial(l)
      let hungUp = c.pump(proc(v: Value): bool = true)
      await waitUntil(proc(): bool = events.count(edgeOpen) >= 1)
      l.close()
      await hungUp
      c.close()
    within run()
    check events.kinds == @[edgeOpen, edgeClose]
    settle()

suite "outward":
  test "the other end stopping speaking leaves the local send open":
    # a bare socket that shuts its side at once, yet reads on
    let server = newAsyncSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    var heard: seq[byte]
    var stillOpen, accepted = false
    proc farEnd() {.async.} =
      let s = await server.accept()
      doAssert posix.shutdown(s.getFd, SHUT_WR) == 0
      while heard.len < corpus.blob.len:
        let data = await s.recv(4096)
        if data.len == 0: break
        heard.add data.toBytes
      s.close()
    proc run() {.async.} =
      let heardAll = farEnd()
      let c = await connect("127.0.0.1", server.getLocalAddr()[1])
      await c.pump(proc(v: Value): bool = true) # ends at the far end's close
      stillOpen = not c.isClosed
      let send = c.sender
      accepted = corpus.allIt(send(it))
      await heardAll
      c.close()
    within run()
    check stillOpen
    check accepted
    check heard == corpus.blob
    server.close()
    settle()
