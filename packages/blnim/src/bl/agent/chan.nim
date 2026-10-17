import std/[asyncdispatch, deques]

export asyncDispatch, deques

type
  ChanError* = object of CatchableError
  Chan*[T] = ref object
    cap: Natural
    received: Deque[T]
    requests: Deque[Future[T]]
    blocked: Deque[(T, Future[void])]
    closed: bool

func newChan*(T: typedesc, cap = 0): Chan[T] =
  Chan[T](cap: cap)

func hasRequest[T](self: Chan[T]): bool =
  self.requests.len > 0

func hasReceived[T](self: Chan[T]): bool =
  self.received.len > 0

func isFull*[T](self: Chan[T]): bool =
  self.received.len >= self.cap

func isBuffered*[T](self: Chan[T]): bool =
  self.cap != 0

func alive*[T](self: Chan[T]): bool =
  not self.closed

proc send*[T](self: Chan[T], val: sink T, fromProc = "send") {.async.} =
  if self.closed:
    raise newException(ChanError, "cannot send on a closed channel")
  if self.hasRequest:
    self.requests.popLast.complete(val)
  elif not self.isFull:
    self.received.addFirst(val)
  else:
    let f = newFuture[void](fromProc)
    self.blocked.addFirst((val, f))
    await f

proc sendMany*[T](self: Chan[T], vals: openArray[T]) {.async.} =
  for each in vals:
    await self.send(each)

proc recv*[T](self: Chan[T], fromProc = "recv"): Future[T] {.async.} =
  if self.hasReceived:
    result = self.received.popLast
    if self.blocked.len > 0:
      let (val, f) = self.blocked.popLast
      self.received.addFirst(val)
      f.complete
  elif self.blocked.len > 0:
    # cap 0 take it straight from the sender
    let (val, f) = self.blocked.popLast
    f.complete
    return val
  elif self.closed:
    raise newException(ChanError, "cannot pull from an empty channel")
  else:
    let f = newFuture[T](fromProc)
    self.requests.addFirst(f)
    return await f

proc close*[T](self: Chan[T]) =
  if self.closed: return
  self.closed = true
  for f in self.requests:
    try:
      f.fail(newException(ChanError, "channel closed"))
    except: discard
  for (_, f) in self.blocked:
    try: f.fail(newException(ChanError, "channel closed"))
    except: discard
  self.blocked.clear()
  self.requests.clear()

template each*(ch, name, body) =
  try:
    while true:
      let name = await ch.recv
      body
  except ChanError: discard