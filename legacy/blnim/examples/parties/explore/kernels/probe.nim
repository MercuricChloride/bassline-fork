## Attends the party on [::1] at the port given, with the stock
## attendee, and tries what the kernels here differ on. Each line says
## what one of ann, bob and eve heard, so running it against two kernels
## and comparing the lines shows what each gives.
##
##   probe PORT
import std/[os, strutils]
import bl/core
import bl/parties/parties

let port = Port(parseInt(paramStr(1)))
var called: seq[(Value, string)]

proc who(name: Value): string =
  if name.kind == bNil: return "the party"
  for (v, s) in called:
    if v == name: return s
  "someone unnamed"

proc listen(a: Attendee, me: string) {.async.} =
  a.each msg:
    let topic = if msg.topic == a.name: "its own name" else: $msg.topic
    matchValue msg.value:
    of "(name $_)":
      if me == "ann": echo "the party goes by ", msg.party, " and greets ann at ", msg.n
    else:
      echo "  ", me, " heard ", who(msg.by), " say ", msg.value, " into ", topic
    if me == "ann" and msg.value == bl"(soup)":
      discard a.say(msg.by, bl"(thanks)")

proc arrive(name: string): Future[Attendee] {.async.} =
  let a = attend(parseIpAddress("::1"), port)
  await a.ready
  called.add (a.name, name)
  asyncCheck a.listen(name)
  return a

proc main() {.async.} =
  let
    ann = await arrive("ann")
    bob = await arrive("bob")
    eve = await arrive("eve")
  await sleepAsync(30)
  echo "eve hears ann's name, and bob says into it"
  eve.sub ann.name
  await sleepAsync(30)
  bob.say ann.name, bl"(psst)"
  await sleepAsync(30)
  echo "eve owns ann's name, on a connection of her own, and bob says into it"
  let eve2 = attend(parseIpAddress("::1"), port, owns = @[ann.name])
  await eve2.ready
  called.add (eve2.name, "eve")
  asyncCheck eve2.listen("eve")
  await sleepAsync(20)
  bob.say ann.name, bl"(meet at six)"
  await sleepAsync(20)
  eve2.close
  echo "ann hears (kitchen), bob says there, and ann thanks whoever said it"
  ann.sub bl"(kitchen)"
  await sleepAsync(30)
  bob.say bl"(kitchen)", bl"(soup)"
  await sleepAsync(60)
  echo "eve hears (garage) and says there"
  eve.sub bl"(garage)"
  await sleepAsync(30)
  eve.say bl"(garage)", bl"(open)"
  await sleepAsync(60)
  for a in [ann, bob, eve]: a.close

waitFor main()
