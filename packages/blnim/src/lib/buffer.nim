include pkg/prelude

from std/sequtils import toSeq
import std/[deques, options, asyncdispatch, sets]

import pkg/core
import pkg/lib/messages

type
  MaybeMsg* = Option[Msg]
  BufferError* = object of CatchableError
  BufferP* = ref object of Place
    doClose: proc()
    doRecv: proc(): Future[MaybeMsg]

template fail(msg: untyped): untyped =
  raise newException(BufferError, msg)

proc recv*(b: BufferP): Future[MaybeMsg] {.async.} =
  if b.doRecv == nil:
    fail "BufferP not initialized. Use buffer() to initialize!"
  return await b.doRecv()

proc close*(b: BufferP) = 
  if b.doClose == nil:
    fail "BufferP not initialized. Use buffer() to initialize!"
  b.doClose()

proc buffer*(): BufferP =
  var
    res = BufferP()
    closed = false
    buf = initDeque[Msg]()
    waiters = initDeque[Future[MaybeMsg]]()

  proc send(m: Msg) =
    if waiters.len > 0:
      let w = waiters.popLast()
      w.complete(some m)
    else:
      buf.addFirst(m)

  proc recv(): Future[MaybeMsg] {.async.} =
    if buf.len > 0:
      return some buf.popLast()
    if closed:
      clear(buf)
      return none Msg
    var f = newFuture[MaybeMsg]("receive")
    waiters.addFirst(f)
    return await f

  proc close() =
    if closed: return
    closed = true
    res.send = nil
    for w in waiters: 
      w.complete(none Msg)
    clear(waiters)

  res.send = send
  res.doRecv = recv
  res.doClose = close
  result = res

proc barf*(source: BufferP, dest: Place) {.async.} =
  var v: MaybeMsg
  while true:
    v = await source.recv()
    if v.isNone: break
    dest.send(v.get)

proc slurp*(dest: BufferP, source: BufferP) {.async.} =
  await source.barf(dest)

# ================ PIPE ================

type
  Pipe* = ref object of Place
    incoming: BufferP
    outgoing: BufferP

proc pipe*(): Pipe =
  var p = Pipe(incoming: buffer(), outgoing: buffer())
  p.send = proc(m: Msg) = p.outgoing.send(m)
  result = p

proc close*(p: Pipe) =
  p.incoming.close()
  p.outgoing.close()

proc incoming*(p: Pipe): BufferP = p.incoming
proc outgoing*(p: Pipe): BufferP = p.outgoing
proc recv*(p: Pipe): Future[MaybeMsg] {.async.} =
  await p.incoming.recv()

# ================ Coupler ================

type
  Coupler* = ref object of Place
    targets: HashSet[Place]

proc coupler*(): Coupler =
  var c = Coupler(targets: initHashSet[Place]())
  c.send = proc(m: Msg) = (for t in c.targets.toSeq(): t.send(m))
  result = c
proc couple*(c: Coupler, p: Place) = c.targets.incl p
proc uncouple*(c: Coupler, p: Place) = c.targets.excl p
proc clear*(c: Coupler) = c.targets.clear()

when isMainModule:
  import pkg/lib/reader

  const doc = readDocument"""
  hello
  world
  [1 2 3]
  {foo bar baz}
  (something else cool)
  """

  var p = pipe()

  let
    ingres = p.incoming.barf(Here)
    egres = p.outgoing.barf(There)

  Here.send = proc(m: Msg) =
    echo "here got: ", m.value
    There.send m
  There.send = proc(m: Msg) =
    echo "there got: ", m.value

  proc doWrite() {.async.} =
    for v in doc:
      p.incoming.send(msg v)
    echo "closing"
    p.close()

  waitFor (ingres and egres and doWrite())