## People who print what they hear and keep it as a transcript, so runs
## can be compared, and conversations that name them by their names.

import bl/[core, conv]
import bl/conv/jam

export core, conv, jam

type
  Person* = ref object of Participant
    name*: Value
    hears*: proc(p: Person, msg: Msg)  ## what it does on hearing, if anything

var
  transcript*: seq[string]  ## everything heard, in order
  quiet* = false

proc show*(line: string) =
  transcript.add line
  if not quiet: echo line

method send*(p: Person, msg: Msg) =
  let by = if msg.by.kind == bNil: "the room" else: $msg.by
  show "    " & $p.name & " heard " & by & ": " & $msg.value
  if not p.hears.isNil: p.hears(p, msg)

proc person*(name: string): Person = Person(name: sym(name))

proc byName*(p: Participant): Value =
  if p of Person: Person(p).name else: Value()

proc room*(rule: Rule): Conversation =
  ## a conversation run by `rule`, naming people by their names
  Conversation(rule: rule, names: byName)

proc jam*(rule: Rule = nil): Jam =
  ## a jam run by `rule`, or by `answers()`, naming people by their names
  Jam(rule: rule, names: byName)

proc says*(p: Person, r: Room, v: Value) =
  show "  " & $p.name & " says " & $v
  if not p.say(r, v): show "    " & $p.name & " is refused"

proc refusing*(c: Conversation, msg: Msg, why: Value): bool =
  ## refuses, telling the speaker (refused WHY)
  c.refuse(msg, bl"(refused $why)")
