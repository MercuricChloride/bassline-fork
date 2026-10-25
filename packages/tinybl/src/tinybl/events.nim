import std/[asyncdispatch, deques]

type
  Emitter*[T] = ref object
    maxQueueSize: int
    listeners: seq[Listener[T]]
    signal: Future[void]

  Listener*[T] = ref object
    inbox: Deque[T]
    signal: Future[void]
    closed: bool

proc newEmitter*[T](maxQueueSize = 10): Emitter[T] =
  Emitter[T](maxQueueSize: maxQueueSize, signal: newFuture[void]("newEmitter"))

func isDone*[T](self: Emitter[T]): bool =
  self.signal.isNil

proc listen*[T](self: Emitter[T]): Listener[T] =
  if self.isDone:
    raise newException(ValueError, "emitter closed")
  result = Listener[T](signal: newFuture[void]("listener"))
  self.listeners.add result

proc wake[T](self: Listener[T])

proc remove*[T](self: Emitter[T], listener: Listener[T]) =
  for i, each in self.listeners:
    if each == listener:
      self.listeners.delete(i)
      each.closed = true
      each.wake
      break

proc close*[T](self: Emitter[T]) =
  if self.isDone: return
  self.signal.complete()
  self.signal = nil
  for each in self.listeners:
    each.closed = true
    each.wake

proc done*[T](self: Emitter[T]): Future[void] =
  if self.isDone:
    result = newFuture[void]("done")
    result.complete
  else:
    result = self.signal

proc emit*[T](self: Emitter[T], val: T): bool {.discardable.} =
  if self.isDone: return
  var toRemove = newSeq[Listener[T]]()
  for each in self.listeners:
    if each.inbox.len == self.maxQueueSize:
      toRemove.add each
    else:
      each.inbox.addLast val
      each.wake
  for each in toRemove:
    when not defined(release):
      echo "removing"
    self.remove each
  true

func closed*[T](self: Listener[T]): bool =
  self.closed

proc wake[T](self: Listener[T]) =
  if not isNil(self.signal):
    let f = self.signal
    self.signal = nil
    f.complete()

proc ready*[T](self: Listener[T]): Future[void] =
  if self.inbox.len > 0 or self.closed:
    result = newFuture[void]("ready")
    result.complete()
  elif isNil(self.signal):
    result = newFuture[void]("ready")
    self.signal = result
  else:
    result = self.signal

iterator items*[T](self: Listener[T]): T =
  while self.inbox.len > 0:
    yield self.inbox.popFirst()

template onEvent*[T](listener: Listener[T], evt, body) =
  ## Drives a loop for event handling. This must be used
  ## within an async function. 
  ## 
  ## Note that `body` is invoked within a loop so a 
  ## break statement will only break from the current 
  ## iteration. To stop early you should remove the
  ## listener
  block:
    let l = listener
    while true:
      await l.ready
      for evt in l:
        body
      if l.closed: break

template onEvent*[T](emitter: Emitter[T], evt, body) =
  ## Creates an anonymous listener and drives an async
  ## event handling loop with async check. 
  ## See `onEvent` for the internals
  asyncCheck(
    (proc(listener: Listener[T]) {.async.} =
      onEvent(listener, evt, body))(emitter.listen))