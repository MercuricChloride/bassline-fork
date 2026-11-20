## A listener joins a wire to `room` for each connection, and `a` and
## `b` each join a wire dialled to the listener's port. The room passes
## on what one wire says to the other, so ann in `a` hears bob in `b`.
##
## Kicking a wire closes its socket once what was written has gone out.
## The wire at the other end stops reading and stays in the room, since
## the far end might still be listening, until a write to it fails.

import bl/[core, conv]
import bl/conv/tcp

type Talker = ref object of Inbox
  name: string

proc talk(t: Talker) {.async.} =
  t.each msg:
    echo t.name, " heard ", msg.value

proc main() {.async.} =
  let
    room = Conversation()
    listener = listen(Port(0), room, "127.0.0.1")
    a = Conversation()
    b = Conversation()
    ann = Talker(name: "ann")
    bob = Talker(name: "bob")
  ann.join a
  bob.join b
  asyncCheck ann.talk
  asyncCheck bob.talk
  let toA = await dial("127.0.0.1", listener.port, a)
  discard await dial("127.0.0.1", listener.port, b)
  await sleepAsync(10)
  echo "room holds ", room.known.len, " wires"

  let n = 1
  discard ann.say(a, bl"(hello from ann $n)")
  discard bob.say(b, bl"!(wave back)")
  await sleepAsync(10)

  a.kick toA
  await sleepAsync(10)
  echo "a kicked its wire, a holds ", a.known.len, ", room holds ", room.known.len

  for i in 1 .. 3:  # into a socket nobody reads any more, until it fails
    discard bob.say(b, bl"(anyone there $i)")
    await sleepAsync(10)
  echo "after bob spoke, room holds ", room.known.len
  listener.close

waitFor main()
