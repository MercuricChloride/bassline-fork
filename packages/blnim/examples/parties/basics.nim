## A party served at the place of `bassline`, and ann, bob, carl and
## dave attending it.
##
## Each is told its name as it arrives. ann hears `status`, where the
## party says who is here, arrives and goes. bob and carl hear (kitchen),
## and ann says dinner is ready there. bob answers ann by saying into what
## she goes by. carl says something outside the dialect, and then into
## `status`, and is told both are invalid. dave owns (desk): what ann says
## there reaches dave alone, and what dave says there reaches bob, who
## hears it. erin asks to own (desk) too, and is let go. carl stops
## hearing (kitchen) and misses the last call. bob leaves, ann hears he
## is dead, and what she says into what he went by reaches nobody. Every
## line shows where the party said it in its order.

import bl/core
import bl/parties/parties

var called: seq[(Value, string)]  # what each goes by, to print who said what

proc who(name: Value): string =
  if name.kind == bNil: return "the party"
  for (v, s) in called:
    if v == name: return s

proc shown(v: Value): string =
  matchValue v:
  of "(name $s)": "(name " & who(s) & ")"
  of "(alive $s)": "(alive " & who(s) & ")"
  of "(dead $s)": "(dead " & who(s) & ")"
  else: $v

proc listen(a: Attendee) {.async.} =
  let me = who(a.name)
  a.each msg:
    let topic = if msg.topic == a.name: "what " & me & " goes by" else: $msg.topic
    echo "  ", msg.n, " ", me, " heard ", who(msg.by), " say ", msg.value.shown, " into ", topic

proc attending(name: string, owns: seq[Value] = @[]): Future[Attendee] {.async.} =
  let a = attend(owns = owns)
  await a.ready
  called.add (a.name, name)
  asyncCheck a.listen
  return a

proc main() {.async.} =
  let p = serve()
  let
    ann = await attending("ann")
    bob = await attending("bob")
    carl = await attending("carl")
    dave = await attending("dave", @[bl"(desk)"])
  echo "ann hears status"
  ann.sub bl"status"
  await sleepAsync(20)

  echo "bob and carl hear (kitchen), and ann says dinner is ready there"
  bob.sub bl"(kitchen)"
  carl.sub bl"(kitchen)"
  await sleepAsync(20)
  ann.say bl"(kitchen)", bl"""(dinner "is ready")"""
  await sleepAsync(20)

  echo "bob answers ann by saying into what she goes by"
  bob.say ann.name, bl"!(coming)"
  await sleepAsync(20)

  echo "carl says something outside the dialect, and then into status"
  carl.send bl"(shout hi)"
  carl.say bl"status", bl"(alive nobody)"
  await sleepAsync(20)

  echo "dave owns (desk). ann says there, then dave does, and bob hears (desk)"
  bob.sub bl"(desk)"
  await sleepAsync(20)
  ann.say bl"(desk)", bl"(is anyone in)"
  await sleepAsync(20)
  dave.say bl"(desk)", bl"(open until five)"
  await sleepAsync(20)

  echo "erin asks to own (desk) too"
  let erin = await attending("erin", @[bl"(desk)"])
  await sleepAsync(20)
  erin.close
  await sleepAsync(20)

  echo "carl stops hearing (kitchen), and ann calls again"
  carl.unsub bl"(kitchen)"
  await sleepAsync(20)
  ann.say bl"(kitchen)", bl"(last call)"
  await sleepAsync(20)

  echo "bob leaves, and ann says into what he went by"
  let went = bob.name
  bob.close
  await sleepAsync(20)
  ann.say went, bl"(where are you)"
  await sleepAsync(20)
  p.close

waitFor main()
