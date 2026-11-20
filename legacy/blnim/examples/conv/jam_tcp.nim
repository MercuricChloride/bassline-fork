## A jam served on a port, and a second jam that reaches it over TCP.
##
## None of this is new code. A listener joins a wire to jam `b` for each
## connection. On the other side a bridge sits in jam `a` and in `link`,
## a plain conversation holding a wire dialled to `b`. What `a` ranks
## goes out over the wire as (Q A), what `b` ranks comes back as
## (Q R A), and each jam keeping an answer once stops it going round.

import bl/[core, conv]
import bl/conv/[jam, tcp]

type Talker = ref object of Inbox
  name: string

proc talk(t: Talker) {.async.} =
  t.each msg:
    echo "  ", t.name, " heard ", msg.value

proc main() {.async.} =
  let
    a = Jam()
    b = Jam()
    link = Conversation()
    bridge = Bridge()
    ann = Talker(name: "ann")
    bob = Talker(name: "bob")
    served = listen(Port(0), b, "127.0.0.1")
  ann.join a
  bob.join b
  asyncCheck ann.talk
  asyncCheck bob.talk
  bridge.join a
  bridge.join link
  discard await dial("127.0.0.1", served.port, link)
  await sleepAsync(20)

  echo "ann says (general \"hi\") into a"
  discard ann.say(a, bl"""(general "hi")""")
  await sleepAsync(20)
  echo "bob says (general \"hey\") into b"
  discard bob.say(b, bl"""(general "hey")""")
  await sleepAsync(20)
  echo "b holds ", b.known.len, " participants, a holds ", a.known.len

waitFor main()
