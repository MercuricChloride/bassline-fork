import std/async
import pkg/core
import pkg/lib/router

type
  RejectedSend* = object of CatchableError

proc request*(s: Send, val: Value): Future[Msg] =
  ##[
  Sends a message with 1 gas to `s`.

  Returns a future that fails if `s` doesn't accept the message
  otherwise resolving when the message is replied to.

  This doesn't setup any timeouts or anything, so ensure that
  you actually use the returned future.
  ]##
  var 
    res = newFuture[Msg]()

  proc resolve(m: Msg): bool =
    if not res.finished():
      res.complete(m)
      result = true

  let 
    req = newMsg(val, resolve, gas = 1)
    accepted = s(req)

  if not(accepted) and not(res.finished):
    res.fail(
      newException(RejectedSend, "rejected send")
    )

  return res