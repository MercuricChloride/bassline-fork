include pkg/prelude

import std/[asyncdispatch, deques]
export asyncdispatch, deques

type
  PipeError* = object of CatchableError
  Pipe*[T] = ref object
    buffer: Deque[T]
    waiters: Deque[Future[T]]
    closed: bool

template pipeErr(msg: string): untyped =
  newException(PipeError, msg)

# ================ ACCESS ================

proc close*(p: Pipe) =
  if not p.closed:
    p.closed = true
    while p.waiters.len > 0:
      p.waiters.popFirst().fail(pipeErr"close: pipe is closed")

proc closed*(p: Pipe): bool =
  return p.closed

# ================ IO ================

proc write*[T](p: Pipe[T], v: T) =
  if p.closed:
    raise pipeErr "write: pipe is closed"
  if p.waiters.len > 0:
    var nextWaiter = p.waiters.popFirst()
    nextWaiter.complete(v)
  else:
    p.buffer.addLast(v)

proc read*[T](p: Pipe[T]): Future[T] {.async.} =
  if p.buffer.len > 0:
    return p.buffer.popFirst()
  elif p.closed:
    raise pipeErr "read: pipe is closed"
  else:
    var f = newFuture[T]()
    p.waiters.addLast(f)
    return await f

proc drain*[T](p: Pipe[T], handler: proc(v: T)) {.async.} =
  while true:
    try:
      handler(await p.read())
    except PipeError:
      if p.closed:
        break

# ================ CONSTRUCTOR ================

proc newPipe*[T](): Pipe[T] =
  Pipe[T](
    buffer: initDeque[T](),
    waiters: initDeque[Future[T]](),
    closed: false
  )