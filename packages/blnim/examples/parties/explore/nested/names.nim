## A connection can own what another goes by, since a name is a topic
## like any other. Then what is said into that name reaches the owner
## and not the one who goes by it. Inside a topic this is how a seat's
## downward stream would be taken: the owner tells a seat by saying into
## its name.

import bl/core
import bl/parties/parties

proc main() {.async.} =
  let lo = parseIpAddress("::1")
  let p = serve(lo, Port(0))
  let ann = attend(lo, p.port)
  await ann.ready
  let mallory = attend(lo, p.port, owns = @[ann.name])
  await mallory.ready
  let bob = attend(lo, p.port)
  await bob.ready
  await sleepAsync(50)
  bob.say ann.name, bl"(for ann)"
  for (who, a) in [("ann", ann), ("mallory", mallory)]:
    discard await a.next  # each was told its name first
    let next = a.next
    if await next.withTimeout(200): echo who, " heard ", next.read.get.value
    else: echo who, " heard nothing"

waitFor main()
