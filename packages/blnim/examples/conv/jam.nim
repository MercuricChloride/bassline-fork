## Two jams and a bridge.
##
## Ann and amy are in jam `a`, bob in jam `b`. Each jam ranks what is
## said into it and says it to everyone in it. Once the bridge is in
## both, it says into each what it hears ranked in the other, and what
## comes back is kept already, so nothing goes round. Asking catches up
## whoever asked, and everyone else hears the ask. The bridge asks the
## other jam too, so what was said there before it came crosses then.
## Each talker drops what it holds already.

import bl/[core, conv]
import bl/conv/jam

type
  Talker = ref object of Inbox
    name: string
    holds: BSet  ## every (Q R A) it has heard

  LoudBridge = ref object of Bridge
    ## a bridge that says what it hears

let
  a = Jam()
  b = Jam()

proc name(c: Conversation): string =
  if c == a: "a" else: "b"

proc talk(t: Talker) {.async.} =
  t.each msg:
    if msg.value notin t.holds:
      t.holds.incl msg.value
      echo "  ", t.name, " heard ", msg.value, " in ", msg.conv.name

proc talker(name: string, c: Conversation): Talker =
  result = Talker(name: name, holds: newBSet())
  result.join c
  asyncCheck result.talk

proc says(t: Talker, c: Conversation, v: Value) {.async.} =
  ## `t` says `v` into `c`, and everyone has a moment to hear it
  echo t.name, " says ", v, " into ", c.name
  if not t.say(c, v): echo "  refused"
  await sleepAsync(10)

method send(b: LoudBridge, msg: Msg) =
  echo "  bridge heard ", msg.value, " in ", msg.conv.name
  procCall Bridge(b).send(msg)

proc main() {.async.} =
  let
    ann = talker("ann", a)
    amy = talker("amy", a)
    bob = talker("bob", b)
    bridge = LoudBridge()
  await ann.says(a, bl"""(general "hi")""")
  await bob.says(b, bl"""(general "hey")""")

  echo "the bridge joins a and b"
  bridge.join a
  bridge.join b
  await amy.says(a, bl"""(general "lunch?")""")

  let carl = talker("carl", b)
  await carl.says(b, bl"(general)")

  echo "b kicks the bridge"
  b.kick bridge
  await bob.says(b, bl"""(general "anyone?")""")

  let dan = talker("dan", a)
  await dan.says(a, bl"(general)")
  await dan.says(a, bl"""(general 9 "made up")""")

waitFor main()
