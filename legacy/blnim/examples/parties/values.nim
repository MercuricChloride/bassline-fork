## Values as topics at the implicit party: two programs that only ever
## say into values and hear them. With a party running (`meet`):
##
##   values cook &
##   values guest
##
## The cook hears (kitchen) and answers each order by saying into what
## whoever ordered goes by. After two orders it stops hearing (kitchen).
## The guest orders three times and waits a second for each order to be
## served, by what is said into `me`, so its third goes unanswered.

import std/[os, times]
import bl/core
import bl/parties/here

proc cook() {.async.} =
  var orders = 0
  bl"(kitchen)".each msg:
    let order = msg.value
    echo "the kitchen heard ", order
    msg.by.say bl"(served $order)"
    inc orders
    if orders == 2:
      bl"(kitchen)".unsub
      echo "the kitchen closes"

proc served(dish: string): Future[bool] {.async.} =
  ## whether the order for `dish` is served within a second. The answer
  ## names its order, so anything else said to the guest is passed over
  let (want, until) = (bl"(served (order $dish))", epochTime() + 1)
  while true:
    let left = int((until - epochTime()) * 1000)
    if left <= 0: return false
    let answer = me.hear
    if not await answer.withTimeout(left):
      answer.abort
      return false
    if answer.read.value == want: return true

proc guest() {.async.} =
  for dish in ["soup", "bread", "pie"]:
    bl"(kitchen)".say bl"(order $dish)"
    if await served(dish): echo "the guest was served ", dish
    else: echo "nobody served ", dish

if paramCount() < 1: quit "values cook|guest"
case paramStr(1)
of "cook":
  asyncCheck cook()
  runForever()
of "guest": waitFor guest()
else: quit "values cook|guest"
