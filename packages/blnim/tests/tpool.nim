## pool: the task pool (custody for the futures a sync Send starts) and
## pub/sub (a token -> messages table, matched by `prefixes`)

import std/[unittest, asyncdispatch]
import bl/[core, msg]
import bl/lib/blmacro

# ================ task pool ================

suite "task pool":
  test "bridge fires the async send and answers understood now":
    var ran = false
    let pool = newTaskPool()
    let s = pool.bridge(proc(m: Msg): Future[void] {.async.} =
      ran = true)
    check s(newMsg(bl go))          # true, synchronously
    check ran                       # body ran to its first suspension

  test "drain waits for work still in flight":
    let
      pool = newTaskPool()
      gate = newFuture[void]("gate")
      s = pool.bridge(proc(m: Msg): Future[void] = gate)
    discard s(newMsg(bl go))
    var drained = false
    let d = pool.drain()
    d.addCallback(proc() = drained = true)
    check not drained
    gate.complete()
    waitFor d
    check drained

  test "a failing send reaches onFail":
    var fails = 0
    let pool = newTaskPool(proc(e: ref Exception) = inc fails)
    let s = pool.bridge(proc(m: Msg): Future[void] {.async.} =
      raise newException(ValueError, "boom"))
    discard s(newMsg(bl go))
    waitFor pool.drain()
    check fails == 1

  test "work handed over after drain still cannot fail silently":
    var fails = 0
    let pool = newTaskPool(proc(e: ref Exception) = inc fails)
    waitFor pool.drain()
    let f = newFuture[void]("late")
    pool.track f
    f.fail(newException(ValueError, "late boom"))
    waitFor sleepAsync(10)
    check fails == 1

# ================ pub / sub ================

proc listener(gas = -1): (Msg, ref seq[Value]) =
  ## a message whose replies pile up in a seq
  let got = new(seq[Value])
  let m = newMsg(bl here, proc(r: Msg): bool =
    got[].add r.value
    true, gas)
  (m, got)

suite "pub / sub":
  test "a published value reaches a subscriber whose token prefixes it":
    let ps = newPubSub()
    let (m, got) = listener()
    ps.sub(m, @[bl person()])
    ps.pub bl person(alice)
    check got[] == @[bl person(alice)]

  test "multicast: every subscriber under a matching token gets it":
    let ps = newPubSub()
    let (a, ga) = listener()
    let (b, gb) = listener()
    ps.sub(a, @[bl person()])
    ps.sub(b, @[bl person()])
    ps.pub bl person(bob)
    check ga[] == @[bl person(bob)]
    check gb[] == @[bl person(bob)]

  test "the subscriber's token is a pattern: siblings do not match":
    let ps = newPubSub()
    let (m, got) = listener()
    ps.sub(m, @[bl person()])
    ps.pub bl person(alice)          # under (person)
    ps.pub bl place(paris)           # not under (person)
    check got[] == @[bl person(alice)]

  test "a bounded subscriber is reaped once its gas is spent":
    let ps = newPubSub()
    let (m, got) = listener(gas = 2)
    ps.sub(m, @[bl t()])
    ps.pub bl t(1)
    ps.pub bl t(2)
    ps.pub bl t(3)
    check got[] == @[bl t(1), bl t(2)]

  test "wire forms: !sub subscribes this message, !pub routes a value":
    let ps = newPubSub()
    let got = new(seq[Value])
    let s = ps.newSend
    let subMsg = newMsg(bl(!sub({person()})), proc(r: Msg): bool =
      got[].add r.value
      true, gas = -1)
    check s(subMsg)
    check s(newMsg(bl(!pub(person(alice), {person()}))))
    check got[] == @[bl person(alice)]

  test "a value carried on no matching token reaches no one":
    let ps = newPubSub()
    let (m, got) = listener()
    ps.sub(m, @[bl person()])
    check ps.pub(bl place(rome)) == 0
    check got[].len == 0

  test "a subscriber whose reply path has gone is reaped":
    let ps = newPubSub()
    let got = new(seq[Value])
    var alive = true
    let m = newMsg(bl here, proc(r: Msg): bool =
      if not alive: return false
      got[].add r.value
      true, gas = -1)
    ps.sub(m, @[bl t()])
    check ps.pub(bl t(1)) == 1
    alive = false
    check ps.pub(bl t(2)) == 0       # the false answer reaps it
    check ps.pub(bl t(3)) == 0
    check got[] == @[bl t(1)]
