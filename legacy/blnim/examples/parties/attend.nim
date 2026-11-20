## Attends the party a program is at, `party` from `bl/parties/here`. What
## is typed, in the textual syntax, goes to the party as it is, and what
## the party says this hears is written a line each:
##
##   attend
##   (sub (kitchen))
##   (say (kitchen) (dinner "is ready"))
##
## A sub or unsub typed holds on every connection after. It ends when
## the typing does.

import bl/[core, conv]
import bl/conv/stdio
import bl/parties/here

let
  typed = Conversation()
  inbox = Inbox()
input.asText = true
inbox.join typed
input.join typed

proc typing() {.async.} =
  inbox.each msg:
    matchValue msg.value:
    of "(sub $t)": party.sub t
    of "(unsub $t)": party.unsub t
    else: party.send msg.value

proc hearing() {.async.} =
  party.each msg:
    echo msg.n, " ", msg.by, " said ", msg.value, " into ", msg.topic

asyncCheck typing()
asyncCheck hearing()
waitFor party.ready
stderr.writeLine "you go by ", party.name
waitFor input.done
waitFor sleepAsync(200)  # for what the party says of the last thing typed
