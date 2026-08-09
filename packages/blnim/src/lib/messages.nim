include pkg/prelude

import std/[asyncfutures, asyncmacro]
import pkg/core

type
  OnSendError* = proc(p: Place, m: Msg, e: ref Exception)
  AsyncSend* = proc(m: Msg): Future[void]
  Send* = proc(m: Msg): void
  
  Msg* = ref object of RootObj
    value: Value
    source: Place
  
  Place* = ref object of RootObj
    doSend: Send

# This is an explicit hook so we can change the send
# behavior if a place has a nil send
# Same with Here & There, it lets us define
# a process local notion of here and there.
var
  Here* = Place()
  There* = Place()
  onSendError*: OnSendError = 
    proc(p: Place, m: Msg, e: ref Exception) =
      raise e
  defaultSend*: Send = proc(m: Msg) = discard

# ================ Message Interactions ================

proc msg*(source: Place, value: Value): Msg =
  Msg(source: source, value: value)
proc msg*(value: Value): Msg =
  Here.msg(value)
proc source*(m: Msg): lent Place = m.source
proc value*(m: Msg): lent Value = m.value

# ================ Place Interactions ================

template trySend(p, m, body: untyped): untyped =
  try:
    body
  except CatchableError as e:
    onSendError(p, m, e)

proc sendAsync(p: Place, m: Msg, s: AsyncSend) {.async.} =
  trySend(p, m): await s(m)
proc send*(p: Place, m: Msg) =
  trySend(p, m):
    if p.doSend != nil:
      p.doSend(m)
    else:
      defaultSend(m)

proc `send=`*(p: Place, send: Send) =
  p.doSend = send
proc `sendAsync=`*(p: Place, send: AsyncSend) =
  p.doSend = proc(m: Msg) = asyncCheck sendAsync(p, m, send)

proc newPlace*(s: Send): Place = 
  result = Place()
  result.send = s
proc newPlace*(s: AsyncSend): Place =
  result = Place()
  result.sendAsync = s


# ================ Seeding ================

proc seed*[T: Place](p: Place, _: typedesc[T]): T =
  T(doSend: p.doSend)
proc seed*[T: Msg](m: Msg, _: typedesc[T]): T =
  T(value: m.value, source: m.source)