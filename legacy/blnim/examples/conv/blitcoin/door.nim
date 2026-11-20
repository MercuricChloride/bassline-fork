## Doors: rules that hold one judgement and stand in front of the rules
## that keep. What breaks a door's judgement it refuses, and the rest it
## takes without saying anything, so the rules after it judge it too.
## A door keeps nothing, so it can stand in front of anything.
##
## A refusal is told to the speaker as (refused WHY), in the
## conversation it spoke into.
##
## `once` passes each value on once, to everyone, the speaker too.

import bl/[core, conv]
export core, conv

proc refusing*(c: Conversation, msg: Msg, why: Value): bool =
  ## refuses, telling the speaker (refused WHY), and answers false
  c.refuse(msg, bl"(refused $why)")

proc door*(why: proc(v: Value): Value): Rule =
  ## takes what `why` answers nil for, and refuses the rest with what it answers
  result = proc(c: Conversation, msg: Msg): bool =
    let w = why(msg.value)
    w.kind == bNil or c.refusing(msg, w)

proc once*(seen: BSet): Rule =
  ## passes each value on once, keeping it in `seen`, and takes it again
  ## without saying anything
  result = proc(c: Conversation, msg: Msg): bool =
    let v = msg.value
    if v notin seen:
      c.keep: seen.incl v
      c.reflect(msg, toSpeaker = true)
    true
