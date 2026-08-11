import std/[asyncdispatch, asyncfutures, tables, deques, options]
import pkg/core
import pkg/lib/reader

type
  BasslineError* = object of CatchableError
  
  PlaceError* = object of BasslineError
  
  Msg* = ref object
    source*: Place
    value*: Value
  
  MaybeMsg* = Option[Msg]

  Bassline* = ref object of RootObj
    places*: Table[Value, Place]

  Place* = ref object of RootObj
    bassline*: Bassline
    mem*: Table[Value, Value]

proc initBassline*(): Bassline =
  Bassline(places: initTable[Value, Place]())

proc msg*(source: Place, value: Value): Msg =
  Msg(source: source, value: value)

proc placeError*(why: string) {.noReturn.} =
  raise newException(PlaceError, why)

proc mread*(self: Place, key: Value): Value

proc mwrite*(self: Place, key: Value, val: Value)

# ================ Place Methods ================

method onMount*(self: Place, key: Value) {.base.} = discard

method onSend*(self: Place, m: Msg) {.base.} = discard

method onRecv*(self: Place): Future[MaybeMsg] {.base, async.} = return none Msg

method onDismount*(self: Place, key: Value) {.base.} = discard

method read*(p: Place, k: Value): Value {.base.} = p.mread(k)

method write*(p: Place, k: Value, v: Value): Value {.base.} =
  result = p.mread(k)
  p.mwrite(k, v)

method describe*(self: Place): Value {.base.} = nilValue()

proc mread*(self: Place, key: Value): Value =
  self.mem.getOrDefault(key, nilValue())

proc mwrite*(self: Place, key: Value, val: Value) =
  self.mem[key] = val

proc `[]`*(self: Place, key: Value): Value =
  self.read(key)

proc `[]=`*(self: Place, key: Value, val: Value) =
  discard self.write(key, val)

# ================ Bassline Methods ================

method onSendError*(
  self: Bassline, 
  p: Place, 
  m: Msg, 
  e: ref Exception) {.base.} = raise e

method onRecvError*(
  self: Bassline, 
  p: Place, 
  e: ref Exception) {.base.} = raise e

method beforeSend*(
  self: Bassline, 
  p: Place, 
  m: Msg): MaybeMsg {.base.} = some m

method beforeRecv*(
  self: Bassline, 
  p: Place): bool {.base.} = true

method lookup*(
  self: Bassline,
  key: Value): Option[Place] {.base.} =
  if self.places.hasKey key:
    some self.places[key]
  else:
    none Place

# ================ Places ================

proc isMounted*(self: Place): bool = self.bassline != nil

proc mount*(bassline: Bassline, key: Value, p: Place) =
  if p.isMounted:
    placeError "mount: place already mounted"
  
  if bassline.places.hasKey(key):
    placeError "mount: already mounted key: " & $key
  
  p.bassline = bassline
  bassline.places[key] = p
  onMount(p, key)

proc dismount*(bassline: Bassline, key: Value) =
  if not bassline.places.hasKey(key):
    return

  let place = bassline.places[key]
  bassline.places.del(key)
  place.onDismount(key)
  place.bassline = nil

proc `[]`*(bassline: Bassline, key: Value): Option[Place] =
  bassline.lookup(key)

proc `[]=`*(bassline: Bassline, key: Value, p: Place) =
  bassline.mount(key, p)

proc send*(self: Place, m: Msg) =
  if not self.isMounted:
    placeError "send: not mounted!"

  let bassline = self.bassline
  try:
    let prep = bassline.beforeSend(self, m)
    if prep.isSome:
      self.onSend(prep.get)
  except CatchableError as e:
    bassline.onSendError(self, m, e)

proc recv*(self: Place): Future[MaybeMsg] {.async.} =
  if not self.isMounted: 
    return none Msg

  let bassline = self.bassline
  try:
    if bassline.beforeRecv(self):
      return await self.onRecv()
    else:
      return none Msg
  except CatchableError as e:
    bassline.onRecvError(self, e)

# ================ Chan ================

type
  Chan = ref object of Place
    waiters: Deque[Future[MaybeMsg]]
    buf: Deque[Msg]

proc chan*(): Chan =
  Chan(waiters: initDeque[Future[MaybeMsg]](), buf: initDeque[Msg]())

method describe(self: Chan): Value =
  dict {
    sym"waiters": num(self.waiters.len),
    sym"buffered": num(self.buf.len)
  }

method onSend*(self: Chan, m: Msg) =
  if self.waiters.len > 0:
    let w = self.waiters.popLast()
    w.complete(some m)
  else:
    self.buf.addFirst(m)

method onRecv*(self: Chan): Future[MaybeMsg] {.async.} =
  if self.buf.len > 0:
    result = some self.buf.popLast()
  else:
    var f = newFuture[MaybeMsg]("chan:onRecv")
    self.waiters.addFirst(f)
    result = await f
method onDismount*(self: Chan, k: Value) =
  for w in self.waiters:
    w.complete(none Msg)
  clear(self.buf)
  clear(self.waiters)

# ================ Cell ================

type
  Cell = ref object of Place
    changed: Future[Option[Value]]

proc cell*(init: Value = nilValue()): Cell = 
  result = Cell(changed: newFuture[Option[Value]]())
  result.mwrite(sym"value", init)

proc notify(self: Cell, val: Option[Value]) =
  self.changed.complete(val)
  self.changed = newFuture[Option[Value]]()

method onSend(self: Cell, m: Msg) =
  self[sym"value"] = m.value

method onDismount(self: Cell, key: Value) =
  self.notify none Value

method onRecv(self: Cell): Future[MaybeMsg] {.async.} =
  let val = await self.changed
  if val.isNone:
    result = none Msg
  else:
    result = some self.msg(val.get)

method write(self: Cell, key: Value, val: Value): Value =
  result = self[key]
  self.mwrite(key, val)
  if key == sym"value" and result != val:
    self.notify some val

method describe(self: Cell): Value =
  dict { sym"value": self[sym"value"] }

# ================ Group ================

type
  Group = ref object of Place
    places: seq[Place]

proc group*(places: varargs[Place]): Group =
  Group(places: @places)

proc keyFor(key: Value, i: int): Value =
  list(key, num i)

method describe(self: Group): Value =
  dict { sym"mounted": num self.places.len }

method onMount(self: Group, k: Value) =
  for i, p in self.places:
    self.bassline.mount(keyFor(k, i), p)
method onDismount(self: Group, k: Value) =
  for i, p in self.places:
    self.bassline.dismount(keyFor(k, i))
method onSend(self: Group, m: Msg) =
  for p in self.places:
    p.send(m)