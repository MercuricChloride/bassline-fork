##[
  The jam, as a conversation. Saying (Q A) into a jam puts A as an
  answer to the question Q, and saying (Q) asks Q. A jam keeps each
  answer once, ranked by when it kept it, and says (Q R A) for it to
  everyone in it, the speaker too. Asked Q, it tells whoever asked
  (Q R A) for every answer to Q it holds, and passes the ask on to
  everyone else unless a bridge asked. Anything else it refuses.

  A jam's rule is `answers()` unless it is given another, so a jam can
  be put together with other rules: `Jam(rule: all(allowed, answers()))`.

  A bridge is in jams and says into each, as (Q A), what it hears in
  another as (Q R A). When someone asks in one jam, it asks the others,
  and what they tell it it says into the first like any other answer.
  A jam doesn't pass on a bridge's ask, so asks don't go round. Nor do
  answers: what comes back to a jam is kept there already, and a
  jam says nothing for an answer it keeps already.
]##
import std/[sequtils, sugar]
import ../core
import ./conv

type
  Jam* = ref object of Conversation
    told: BSet  ## every (Q R A) said, those for one Q together in rank order
    kept: BSet  ## every (Q A) kept
    next: int   ## the rank the next answer gets

  Bridge* = ref object of Speaker

iterator ask*(jam: Jam, q: Value): Value {.closure.} =
  let q = q  # a lambda in a closure iterator doesn't see its parameters
  if not jam.told.isNil:
    for each in jam.told.itemsFrom(m => m.head >= q, m => m.head <= q):
      yield each

proc answering(c: Conversation, msg: Msg): bool =
  let (jam, v) = (Jam(c), msg.value)
  if not v.isKind(bRec, unmarked): return false
  case v.items.len
  of 2:
    jam.keep:
      if jam.kept.isNil: (jam.kept, jam.told) = (newBSet(), newBSet())
      if v notin jam.kept:
        let
          (q, a, r) = (v.items[0], v.items[1], jam.next)
          told = bl"($q $r $a)"
        inc jam.next
        jam.kept.incl v
        jam.told.incl told
        jam.say told
    true
  of 1:
    jam.tell(msg.by, toSeq jam.ask(v.head))
    let asker = jam.member(msg.by)
    if asker.isNil or not (asker of Bridge): jam.reflect(msg, toSpeaker = false)
    true
  else: false

proc answers*(): Rule =
  ## a jam's rule: an answer kept once and said ranked, or a question
  ## answered, to whoever asked, with every answer to it the jam holds.
  ## An answer is ranked once it is kept, so answers taken together are
  ## ranked in turn
  answering

method send*(jam: Jam, msg: Msg): bool =
  ## by default a jam's rule is `answers()`
  if jam.rule.isNil: answering(jam, msg) else: jam.rule(jam, msg)

method send*(b: Bridge, msg: Msg) =
  ## an answer heard ranked in one jam, said into the others, or an ask
  ## heard in one, asked of the others
  let v = msg.value
  if not v.isKind(bRec, unmarked): return
  case v.items.len
  of 3:
    let (q, a) = (v.items[0], v.items[2])
    b.say(bl"($q $a)", but = msg.room)
  of 1:
    b.say(v, but = msg.room)
  else: discard
