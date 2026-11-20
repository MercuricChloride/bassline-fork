## A door: a room with its own dialect, (say NAME TEXT) and (catch-up),
## in front of a jam it doesn't hold, only its room. Each person in the
## door has a voice in the jam that tells them what the jam says. What
## a voice says into the jam is part of the door's transaction, so a
## door rule that refuses after the jam took something undoes it, and
## the jam keeps nothing.

import ./rules

type Voice = ref object of Person
  door: Conversation
  whose: Value

method send(v: Voice, msg: Msg) =
  ## (general R (NAME TEXT)) heard in the jam, told in the door as
  ## (say NAME TEXT)
  let x = msg.value
  if x.isKind(bRec, unmarked) and x.len == 3 and x[2].isKind(bRec, unmarked) and x[2].len == 2:
    let (n, t) = (x[2][0], x[2][1])
    v.door.tell(v.whose, [bl"(say $n $t)"])

proc speaking(voices: BTree[Value, Voice], jam: Room): Rule =
  result = proc(c: Conversation, msg: Msg): bool =
    let (v, voice) = (msg.value, voices[msg.by])
    if v == bl"(catch-up)": return voice.say(jam, bl"(general)")
    if v.isKind(bRec, unmarked) and v.len == 3 and v.head == bl"say" and v[1] == msg.by:
      let (n, t) = (v[1], v[2])
      return voice.say(jam, bl"(general ($n $t))") or c.refusing(msg, bl"refused-by-jam")
    c.refusing(msg, bl"not-said-here")

let
  jamRoom = jam()
  voices = newBTree[Value, Voice]()
  door = room(all(speaking(voices, jamRoom), cap(40)))
  (jim, ann, bea) = (person"jim", person"ann", person"bea")

proc seat(p: Person) =
  ## whoever holds the door seats someone in it, with a voice in the jam
  p.join door
  let (n, whose) = (p.name, p.name)
  let voice = Voice(name: bl"(door $n)", door: door, whose: whose)
  discard voice.join jamRoom
  voices[p.name] = voice

jim.join jamRoom
jim.says(jamRoom, bl"""(general (jim "early"))""")
seat ann
seat bea
ann.says(door, bl"(catch-up)")
ann.says(door, bl"""(say ann "hi")""")
bea.says(door, bl"""(say ann "it's me")""")
bea.says(door, bl"""(say bea "a much longer message than this door takes")""")
jim.says(jamRoom, bl"""(general (jim "next"))""")
ann.says(door, bl"(wave)")
