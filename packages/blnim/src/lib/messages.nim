include pkg/prelude
import pkg/core

type
  Send* = proc(m: Msg)
  
  Msg* = ref object of RootObj
    value: Value
    source: Place
  
  Place* = ref object of RootObj
    doSend: proc(x: Msg)

# This is an explicit hook so we can change the send
# behavior if a place has a nil send
# Same with GlobalPlace, it lets us define
# a process local notion of here.
var
  Here* = Place()
  defaultSend* = proc(m: Msg) = discard

# ================ Place Interactions ================

proc send*(p: Place, m: Msg) =
  if p.doSend != nil:
    p.doSend(m)
  else:
    defaultSend(m)

proc `send=`*(p: Place, send: Send) =
  p.doSend = send

# ================ Message Interactions ================

proc msg*(source: Place, value: Value): Msg =
  Msg(source: source, value: value)
proc source*(m: Msg): lent Place = m.source
proc value*(m: Msg): lent Value = m.value

# ================ Seeding ================

proc seed*[T: Place](p: Place, _: typedesc[T]): T =
  T(doSend: p.doSend)
proc seed*[T: Msg](m: Msg, _: typedesc[T]): T =
  T(value: m.value, source: m.source)