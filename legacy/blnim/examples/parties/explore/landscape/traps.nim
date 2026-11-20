## Four things a party does today that other systems ran into, each
## shown at a party served on [::1]:
##
## 1. A name is a topic anyone may hear, and `status` says every name.
##    eve hears status, then ann's name, and hears what bob says to ann.
##    (NATS reply inboxes had this: anyone allowed `_INBOX.>` hears every
##    reply.)
## 2. A program can close that with the party as it is, by owning its own
##    name as the first thing it says. fay does, and eve, hearing fay's
##    name, no longer hears what bob says to her.
## 3. When an owner goes, its topic falls back to everyone who hears it.
##    dave owns (desk) and bob hears it. While dave is there, what ann
##    says into (desk) reaches dave alone. Once he goes, it reaches bob.
## 4. An owner isn't told who begins to hear its topic, so it can't greet
##    a new hearer the way the party greets new hearers of `status`.
##
## Build and run from packages/blnim:
##   nim c -r --hints:off --nimcache:examples/parties/explore/landscape/cache \
##     examples/parties/explore/landscape/traps.nim

import std/deques
import bl/core
import bl/parties/parties

let here = parseIpAddress("::1")
var heard: seq[(string, Said)]  # who heard what, in the order heard

proc listen(who: string, a: Attendee) {.async.} =
  a.each msg:
    heard.add (who, msg)

proc attending(who: string, port: Port, owns: seq[Value] = @[]): Future[Attendee] {.async.} =
  let a = attend(here, port, owns)
  await a.ready
  asyncCheck listen(who, a)
  return a

type Raw = ref object
  ## a connection by hand, to say something first that depends on the
  ## name the party gives it
  socket: AsyncSocket
  decoder: Decoder
  kept: Deque[Value]

proc read(r: Raw): Future[Value] {.async.} =
  while r.kept.len == 0:
    let data = await r.socket.recv(4096, flags = {})
    if data.len == 0: return Value()
    r.decoder.buf.add data.toBytes
    for view in r.decoder.checked: r.kept.addLast view.toValue
    r.decoder.compact
  return r.kept.popFirst

proc ownsItsName(who: string, port: Port): Future[Value] {.async.} =
  ## connects, owns the name it is given, and hears from then on
  let r = Raw(socket: newAsyncSocket(AF_INET6, buffered = false), decoder: newDecoder())
  await r.socket.connect("::1", port)
  let first = await r.read
  var name: Value
  matchValue first:
  of "(name $_ $s $_)": name = s
  else: quit "no name"
  await r.socket.send(bl"(own {$name})".ce.toString, flags = {})
  proc hearing() {.async.} =
    while true:
      let v = await r.read
      if v.kind == bNil: return
      matchValue v:
      of "(said $n $t $x $by)": heard.add (who, Said(n: n.num.toInt, topic: t, by: by, value: x))
      else: discard
  asyncCheck hearing()
  return name

proc show(what: string, value: Value) =
  var who: seq[string]
  for (w, s) in heard:
    if s.value == value: who.add w
  echo "  ", what, ": ", if who.len == 0: "nobody" else: $who

proc main() {.async.} =
  let
    p = serve(here, Port(0))
    port = p.port
    ann = await attending("ann", port)
    bob = await attending("bob", port)
    eve = await attending("eve", port)
  eve.sub bl"status"
  await sleepAsync(30)

  echo "1. eve learns ann's name from status, hears it, and bob says to ann"
  let annName = ann.name
  var learned = false
  for (w, s) in heard:
    if w == "eve" and s.value == bl"(alive $annName)": learned = true
  if not learned: quit "status didn't tell eve of ann"
  eve.sub annName
  await sleepAsync(30)
  bob.say ann.name, bl"(pin 1234)"
  await sleepAsync(30)
  show "(pin 1234) reached", bl"(pin 1234)"

  echo "2. fay owns her own name first. eve hears it, and bob says to fay"
  let fay = await ownsItsName("fay", port)
  await sleepAsync(30)
  eve.sub fay
  await sleepAsync(30)
  bob.say fay, bl"(pin 5678)"
  await sleepAsync(30)
  show "(pin 5678) reached", bl"(pin 5678)"

  echo "3. dave owns (desk), bob hears it, ann says there, dave goes, ann says again"
  let dave = await attending("dave", port, @[bl"(desk)"])
  bob.sub bl"(desk)"
  await sleepAsync(30)
  ann.say bl"(desk)", bl"(card 1111)"
  await sleepAsync(30)
  show "(card 1111), dave there, reached", bl"(card 1111)"
  dave.close
  await sleepAsync(30)
  ann.say bl"(desk)", bl"(card 2222)"
  await sleepAsync(30)
  show "(card 2222), dave gone, reached", bl"(card 2222)"

  echo "4. gus owns (till). carl begins to hear it. what gus is told of carl"
  let gus = await attending("gus", port, @[bl"(till)"])
  await sleepAsync(30)
  let before = heard.len
  let carl = await attending("carl", port)
  carl.sub bl"(till)"
  await sleepAsync(30)
  var told = 0
  for (w, s) in heard[before .. ^1]:
    if w == "gus": inc told
  echo "  gus was told ", told, " things"

  for a in [ann, bob, eve, gus, carl]: a.close
  p.close

waitFor main()
