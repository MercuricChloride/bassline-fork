## Two conversations and a bridge.
##
## `plain` passes on what is said, as said, to everyone else. `ranked`
## gives each value its place and says `(heard N V)` to everyone, the
## speaker too. The bridge is in both, and says into each what it hears
## in the other, so `a` hears its own words as `ranked` heard them
## without ever being in it. Once `ranked` kicks the bridge it carries
## nothing more.

import bl/[core, conv]

blet"{hi there again}"

type
  Talker = ref object of Inbox
    name: string

  Bridge = ref object of Speaker

  Ranked = ref object of Conversation
    next: int

proc talk(t: Talker) {.async.} =
  t.each msg:
    echo t.name, " heard ", msg.value

method send(b: Bridge, msg: Msg) =
  b.say(msg.value, but = msg.room)

method left(b: Bridge, r: Room) =
  procCall Speaker(b).left(r)
  echo "bridge left"

method send(r: Ranked, msg: Msg): bool =
  let
    n = r.next
    v = msg.value
  inc r.next
  r.say bl"(heard $n $v)"
  true

proc main() {.async.} =
  let
    plain = Conversation()
    ranked = Ranked()
    a = Talker(name: "a")
    c = Talker(name: "c")
    bridge = Bridge()
  a.join plain
  bridge.join plain
  c.join ranked
  bridge.join ranked
  asyncCheck a.talk
  asyncCheck c.talk

  discard a.say(plain, hi)
  await sleepAsync(10)
  discard c.say(ranked, there)
  await sleepAsync(10)
  ranked.kick bridge
  discard c.say(ranked, again)
  discard a.say(plain, again)
  await sleepAsync(10)

waitFor main()
