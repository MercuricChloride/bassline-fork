##[
  The jam, as a conversation. Saying (Q A) into a jam puts A as an
  answer to the question Q, and saying (Q) asks Q. A jam keeps each
  answer once, ranked by when it heard it, and says (Q R A) for it to
  everyone in it, the speaker too. Asked Q, it tells whoever asked
  (Q R A) for every answer to Q it holds, and passes the ask on to
  everyone else. Anything else it refuses.

  A bridge is in jams and says into each, as (Q A), what it hears in
  another as (Q R A). When someone asks in one jam, it asks the others,
  and what they tell it it says into the first like any other answer.
  It doesn't pass on an ask another bridge made, so asks don't go round.
  Nor do answers: what comes back to a jam is kept there already, and a
  jam says nothing for an answer it keeps already.
]##
import std/[sequtils, sugar]
import ../core
import ./conv

type
  Jam* = ref object of Conversation
    told: BSet  ## every (Q R A) said, those for one Q together in rank order
    next: int   ## the rank the next answer gets

  Bridge* = ref object of Speaker

iterator ask*(jam: Jam, q: Value): Value =
  if not jam.told.isNil:
    for each in jam.told.itemsFrom(m => m.head > q,
                                   m => m.head < q):
      if each.head > q: break
      yield each

method send*(jam: Jam, msg: Msg): bool =
  ## an answer kept and said ranked, or a question answered, to whoever
  ## asked, with every answer to it the jam holds
  let v = msg.value
  if not v.isKind(bRec, unmarked): return false
  case v.items.len
  of 2:
    if jam.fresh v:
      let
        (q, a, r) = (v.items[0], v.items[1], jam.next)
        told = bl"($q $r $a)"
      inc jam.next
      if jam.told.isNil: jam.told = newBSet()
      jam.told.incl told
      jam.say told
    true
  of 1:
    jam.tell(msg.by, toSeq jam.ask(v.head))
    jam.reflect(msg, toSpeaker = false)
    true
  else: false

method send*(b: Bridge, msg: Msg) =
  ## an answer heard ranked in one jam, said into the others, or an ask
  ## heard in one, asked of the others
  let v = msg.value
  if not v.isKind(bRec, unmarked): return
  case v.items.len
  of 3:
    let (q, a) = (v.items[0], v.items[2])
    b.say(bl"($q $a)", but = msg.conv)
  of 1:
    if not (msg.by of Bridge): b.say(v, but = msg.conv)
  else: discard