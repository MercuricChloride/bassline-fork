include pkg/prelude

import std/sets
import pkg/core
import pkg/lib/pipes

export pipes

# This should probably be done elsewhere
# But rn it's saul goodman
discard getGlobalDispatcher()

type
  Stateless* = object
  Handler*[T;S] = proc(v: T, state: var S): void
  Panic*[T] = proc(a: Actor[T], e: ref Exception) {.closure, gcsafe.}
  ActorStatus = enum asIdle, asRunning, asClosing, asDone
  Actor*[T] = ref object
    future: Future[void]
    pending: seq[proc() {.closure, gcSafe.}]
    currentStatus: ActorStatus
    place: Place[T]
    doStart: proc()
    doStop: proc(): Future[void]
    doSend: proc(v: T)

  Place*[T] = ref object
    handles: HashSet[Actor[T]]
    panic*: Panic[T]
    eager*: bool

# ================ ACTOR VIEWS ================

func idle*(a: Actor): bool =
  a.currentStatus == asIdle
func running*(a: Actor): bool =
  a.currentStatus == asRunning
func closing*(a: Actor): bool =
  a.currentStatus == asClosing
func done*(a: Actor): bool =
  a.currentStatus == asDone

func active*(a: Actor): bool =
  a.running or a.closing
func failed*(a: Actor): bool =
  a.future.failed

# ================ PLACE VIEWS ================

func idle*[T](g: Place[T]): seq[Actor[T]] =
  for a in g.handles:
    if a.idle: result.add a

func running*[T](g: Place[T]): seq[Actor[T]] =
  for a in g.handles:
    if a.running: result.add a

func active*[T](g: Place[T]): seq[Actor[T]] =
  for a in g.handles:
    if a.active: result.add a

# ================ PLACE / ACTOR INTERACTIONS ================

proc send*(a: Actor, v: auto) = 
  a.doSend(v)
proc send*(g: Place, v: auto) =
  for a in g.running: a.send(v)

proc start*(a: Actor) =
  a.doStart()
proc start*(g: Place) =
  for a in g.idle: a.start()

proc stop*(a: Actor) {.async.} =
  await a.doStop()
proc stop*(g: Place) {.async.} =
  for a in g.active: await a.stop()

proc clear*(p: Place) {.async.} =
  await stop p
  clear p.handles

proc addCallback*(a: Actor, cb: auto ) =
  a.future.addCallback(cb)

template onClose*(a, body: untyped): untyped =
  a.addCallback(proc() = body)

# ================ PLACE / ACTOR CONSTRUCTION ================

proc newPlace*[T](eager = false): Place[T] =
  Place[T](
    handles: initHashSet[Actor[T]](),
    eager: eager
  )

proc spawn*[T, S](
  place: Place[T], 
  handler: Handler[T, S], 
  init: S = S.default()
): Actor[T] =
  var
    drainFut: Future[void]
    state = init
    inbox = newPipe[T]()
    handle = Actor[T](
      place: place,
      currentStatus: asIdle,
      future: newFuture[void]()
    )

  proc doCleanup() =
    handle.currentStatus = asDone
    place.handles.excl handle
    if drainFut.failed:
      let e = drainFut.readError()
      if place.panic == nil:
        fail(handle.future, e)
        return
      place.panic(handle, e)
    complete(handle.future)

  proc doStep(v: T) = handler(v, state)

  proc doSend(v: T) =
    if not inbox.closed:
      inbox.write(v)

  proc doStart() =
    if not handle.idle: return
    handle.currentStatus = asRunning
    
    drainFut = inbox.drain(doStep)
    drainFut.addCallback(doCleanup)

  proc doStop() {.async.} =
    case handle.currentStatus
    of asIdle: return
    of asRunning:
      handle.currentStatus = asClosing
      inbox.close()
      await handle.future
    of asClosing, asDone:
      await handle.future
  
  handle.doStart = doStart
  handle.doStop = doStop
  handle.doSend = doSend
  place.handles.incl handle

  if place.eager:
    handle.start()

  return handle

proc spawn*[T](
  place: Place[T],
  handler: proc(v: T),
): Actor[T] =
  place.spawn(proc(v: T, s: var Stateless) = handler(v))

proc door*[T](
  place: Place[T],
  handler: Handler[T, Place[T]]
): Actor[T] =
  place.spawn(handler, place)
proc door*[T](
  place: Place[T],
  handler: proc(self: Place[T])
): Actor[T] =
  place.spawn(proc(v: T, self: var Place[T]) = handler(self), place)

template spawnIt*(p, Input, State, body: untyped): untyped =
  p.spawn(proc(it {.inject.}: Input, state {.inject.}: var State) = body)

template spawnIt*(p, Input, body: untyped): untyped =
  p.spawn(proc(it {.inject.}: Input) = body)

when isMainModule:
  import pkg/lib/reader
  var eager = true

  proc logger(msg: string): Handler[Value, int] =
    proc(v: Value, _: var int) =
      echo msg, v

  proc doRelay(v: Value, places: var HashSet[Place[Value]]) =
    for other in places:
      send other, v

  var
    root = newPlace[Value](eager)
    aPlace = newPlace[Value](eager)
    anotherPlace = newPlace[Value](eager)
    places = [aPlace, anotherPlace].toHashSet()

  discard anotherPlace.spawn(logger("another: "))
  discard aPlace.spawn(logger("aPlace: "))
  discard root.spawn(doRelay, places)

  proc cleanup(): Future[void] {.async.} =
    for place in [root, anotherPlace, aPlace]:
      let before = place.running.len
      await stop place
      let after = place.running.len
      echo "before: ", before
      echo "after: ", after

  var count = 0
  let
    a = root.spawnIt(Value, HashSet[Value]):
      if it in state:
        echo "already have: ", it
      else:
        state.incl it
        echo "new value: ", it
        echo "state: ", state
    _ = anotherPlace.spawnIt(Value):
      inc count
      echo "received ", count, " messages!"
    bomb = root.spawnIt(Value):
      raise newException(ValueError, "ima firin my lahzors")

  root.panic = proc(a: Actor[Value], e: ref Exception) =
      echo "fuck!", e.msg

  onClose a:
    echo "a is done"
  
  for i in 1 .. 3:
    a.send num(i)

  for place in places:
    start place

  for i in 1 .. 10:
    send root, num(i)

  send root, sym"goodbye"

  waitFor cleanup()

  echo "total size:",  aPlace.handles.len