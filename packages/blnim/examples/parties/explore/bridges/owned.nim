## An owned topic across machines: three parties in a ring, (desk) owned
## by dave at party 0, its home. The gates at parties 1 and 2 hold (desk)
## for him.
##
## yan at party 2 asks at the desk, and only dave hears it. He answers
## yan, and says the desk is open, which everyone hears once. zoe at
## party 1 asks to own (desk) and is let go. dave goes, and erin, who has
## been waiting at party 0 to own (desk), has it: what she says reaches
## every party from the same seats.

import std/[sequtils, strutils]
import bl/core
import ./fabric

let
  here = parseIpAddress("::1")
  desk = bl"(desk)"

proc shown(v: Value): string =
  if v.kind == bBytes: ($v)[0 .. 9] & "…" else: $v

proc listen(who: string, a: Attendee, answers: bool) {.async.} =
  a.each msg:
    if msg.by.kind == bNil and msg.topic == a.name:
      matchValue msg.value:
      of "(invalid $_)": echo "  ", who, " was told ", msg.value
      else: discard
    elif msg.by.kind != bNil:
      let into = if msg.topic == a.name: "what " & who & " goes by" else: $msg.topic
      echo "  ", who, " heard ", msg.value, " by ", msg.by.shown, " into ", into
      if answers and msg.topic == desk:
        echo "  ", who, " answers into what that was said by"
        discard a.say(msg.by, bl"(come in)")

proc attending(who: string, p: (IpAddress, Port), owns: seq[Value] = @[],
               hears = true): Future[Attendee] {.async.} =
  let a = attend(p[0], p[1], owns = owns)
  if hears: a.sub desk
  asyncCheck listen(who, a, answers = owns.len > 0)
  return a

proc main() {.async.} =
  let places = (0 ..< 3).mapIt((here, serve(here, Port(0)).port))
  discard gate(places[0][0], places[0][1], @[desk])
  for p in places[1 .. 2]: discard gate(p[0], p[1], @[], owned = @[desk])
  for (i, j) in [(0, 1), (1, 2), (0, 2)]: discard bridge(places[i], places[j])
  let
    dave = await attending("dave", places[0], @[desk], hears = false)
    ann = await attending("ann at 0", places[0])
    bob = await attending("bob at 1", places[1])
    yan = await attending("yan at 2", places[2])
  await sleepAsync(200)

  echo "yan asks at the desk"
  yan.say(desk, bl"(is anyone in)")
  await sleepAsync(100)

  echo "dave says the desk is open"
  dave.say(desk, bl"(open until five)")
  await sleepAsync(100)

  echo "zoe at 1 asks to own (desk)"
  let zoe = await attending("zoe", places[1], @[desk], hears = false)
  await sleepAsync(100)
  zoe.close

  echo "erin waits at 0 to own (desk), and dave goes"
  let erin = await attending("erin", places[0], @[desk], hears = false)
  await sleepAsync(100)
  dave.close
  await sleepAsync(1500)
  echo "erin says the desk is open again, and yan asks again"
  erin.say(desk, bl"(open until six)")
  await sleepAsync(100)
  yan.say(desk, bl"(is anyone in)")
  await sleepAsync(100)
  for a in [ann, bob, yan, erin]: a.close

waitFor main()
