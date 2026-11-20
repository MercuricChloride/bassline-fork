## One process, two conversations: `ctl`, where what is said spawns
## participants, and `room`, where they talk.
##
## The spawner is in both. When it hears `!(spawn KIND ARG)` it makes a
## participant of that kind and joins it to every other conversation it
## is in. Making is its own business: it knows a few kinds and refuses
## the rest.

import std/sugar
import bl/[core, conv]

blet"{spawn logger}"

type
  Logger = ref object of Participant
    tag: Value

  Spawner = ref object of Speaker
    kinds: BTree[Value, (Value) -> Participant]

method send(l: Logger, msg: Msg) =
  echo l.tag, " ", msg.value

method send(s: Spawner, msg: Msg) =
  let v = msg.value
  if not (v.isKind(bRec, marked) and v.len == 3 and v[0] == spawn): return
  if v[1] notin s.kinds: return
  let made = s.kinds[v[1]](v[2])
  for r in s.rooms:
    if r != msg.room: made.join r

let
  ctl = Conversation()
  room = Conversation()
  spawner = Spawner(kinds: newBTree[Value, (Value) -> Participant]())
  me = Participant()  # one that only speaks, so it hears nothing

spawner.kinds[logger] = (tag: Value) => Participant(Logger(tag: tag))
spawner.join ctl
spawner.join room
me.join ctl
me.join room

discard me.say(ctl, bl"!(spawn foo bar)")   # a kind it doesn't know
discard me.say(ctl, bl"!(spawn logger 1)")
discard me.say(room, bl"hi")
discard me.say(ctl, bl"!(spawn logger 2)")
discard me.say(ctl, bl"(spawn logger 3)")   # unmarked: nothing to do
discard me.say(room, bl"there")
