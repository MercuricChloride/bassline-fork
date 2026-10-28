import std/[asyncfutures, asyncmacro, deques]
export asyncfutures, asyncmacro, deques

type
  Emitter*[T] = ref object
    maxQueueSize: int
    listeners: seq[Listener[T]]
    signal: Future[void]
    heard: Future[void]

  Source*[T] = ref object
    emitter: Emitter[T]

  Listener*[T] = ref object
    inbox: Deque[T]
    signal: Future[void]
    closed: bool

proc newEmitter*[T](maxQueueSize = 10): Emitter[T] =
  Emitter[T](maxQueueSize: maxQueueSize, signal: newFuture[void]("newEmitter"),
    heard: newFuture[void]("emitter ready"))

func isDone*[T](self: Emitter[T]): bool =
  self.signal.isNil

proc listen*[T](self: Emitter[T]): Listener[T] =
  if self.isDone:
    raise newException(ValueError, "emitter closed")
  result = Listener[T](signal: newFuture[void]("listener"))
  self.listeners.add result
  if not self.heard.finished:
    self.heard.complete()

proc wake[T](self: Listener[T]) =
  if not isNil(self.signal):
    let f = self.signal
    self.signal = nil
    f.complete()

proc stop[T](self: Listener[T]) =
  self.closed = true
  self.wake

proc give[T](self: Listener[T], val: sink T) =
  if not self.closed:
    self.inbox.addLast(val)
    self.wake

proc close*[T](self: Emitter[T]) =
  if self.isDone: return
  self.signal.complete()
  self.signal = nil
  for each in self.listeners:
    each.stop
  if not self.heard.finished:
    self.heard.complete()

proc done*[T](self: Emitter[T]): Future[void] =
  if self.isDone:
    result = newFuture[void]("done")
    result.complete
  else:
    result = self.signal

proc ready*[T](self: Emitter[T]): Future[void] =
  ## completes at the first listen, or when the emitter closes, so whoever
  ## waits on it knows there is someone to emit to or never will be
  self.heard

proc emit*[T](self: Emitter[T], val: sink T): bool {.discardable.} =
  ## hands val to every listener
  ## A full listener is stopped, and stopped listeners are removed
  if self.isDone:
    return false
  var
    kept = 0
    last: Listener[T]
  for i in 0 ..< self.listeners.len:
    let l = self.listeners[i]
    if not l.closed and l.inbox.len == self.maxQueueSize:
      l.stop
    if l.closed:
      continue
    self.listeners[kept] = l
    inc kept
    if not last.isNil:
      last.give(val)
    last = l
  self.listeners.setLen kept
  if not last.isNil:
    last.give(move val)
  true

proc source*[T](self: Emitter[T]): Source[T] =
  Source[T](emitter: self)

func isDone*[T](self: Source[T]): bool =
  self.emitter.isDone

proc listen*[T](self: Source[T]): Listener[T] =
  self.emitter.listen

proc close*[T](self: Source[T]) =
  self.emitter.close

proc done*[T](self: Source[T]): Future[void] =
  self.emitter.done

func closed*[T](self: Listener[T]): bool =
  self.closed

proc close*[T](self: Listener[T]) =
  self.inbox.clear()
  self.stop

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
  ## iteration. To stop early close the listener
  block:
    let l = listener
    while true:
      await l.ready
      for evt in l:
        body
      if l.closed: break