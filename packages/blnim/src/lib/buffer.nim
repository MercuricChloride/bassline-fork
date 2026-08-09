include pkg/prelude

import std/[deques, options, asyncdispatch]

import pkg/core
import pkg/lib/[messages, reader]

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

when isMainModule:

  const doc = readDocument"""
  hello
  world
  [1 2 3]
  {foo bar baz}
  (something else cool)
  """

  var b = buffer()

  proc doRead() {.async.} =
    var m: MaybeMsg
    while true:
      await sleepAsync(1000)
      m = await b.recv()
      if m.isSome:
        echo "read: ", m.get.value
      else:
        break

  proc doWrite() {.async.} =
    for v in doc:
      b.send(msg v)
    echo "closing"
    b.close()  

  

  waitFor (doRead() and doWrite())