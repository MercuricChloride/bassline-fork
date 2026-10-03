## Sends: what you tell.
##
## A send takes a query and an answer, runtime things as readily as
## values, and says whether it took them. It is local: a program telling
## something it holds, never a call into someone else. Like a search it
## is an object, closing over wherever it puts things, and some sends
## can be written down. Written down a send is opaque: it says only that
## it is a send and what it sends to, by identity, and what those are is
## found by asking about them.
##
##   !{!(kind send) !(to ID) …}
##
## Reading one back is a search from identities to sends: what an
## identity reaches depends on where it is read, and where nothing
## answers for it, it reaches nothing.

import ../core
import ./[queries, stream]
export queries

refuseWith ValueError

type
  Send*[Q, A] = ref object
    sending: proc(q: Q, a: A): bool
    denoting: proc(): Value
    ## nil for a send with no denotation

proc newSend*[Q, A](send: proc(q: Q, a: A): bool,
                    denote: proc(): Value = nil): Send[Q, A] =
  ## a send that tells `send`, and writes itself down with `denote` if it
  ## can. A send needs no name of its own: it is told apart by what it
  ## sends to
  Send[Q, A](sending: send, denoting: denote)

proc send*[Q, A](s: Send[Q, A], q: Q, a: A): bool =
  ## tells `s` that `a` answers `q`, answering whether it was taken
  s.sending(q, a)

proc denotable*(s: Send): bool =
  s.denoting != nil

proc toValue*(s: Send): Value =
  ## the send written down. Refuses a send that has no denotation
  guard s.denotable, "this send has no denotation"
  s.denoting()

proc sendTo*(ids: varargs[Value]): Value =
  ## a send written down: !{!(kind send) !(to ID) …}
  var members = @[order(KindQ, SendKind)]
  for id in ids: members.add target(id)
  obj(members)

proc tee*[Q, A](parts: openArray[Send[Q, A]]): Send[Q, A] =
  ## tells every part, and was taken if any part took it. Written down,
  ## it sends to everything its parts send to
  let ps = @parts
  proc send(q: Q, a: A): bool =
    for p in ps:
      if p.send(q, a): result = true
  var denote: proc(): Value = nil
  if initStream(ps).every(proc(p: Send[Q, A]): bool = p.denotable):
    denote = proc(): Value =
      sendTo(collect(initStream(ps).flatMap(proc(p: Send[Q, A]): Stream[Value] =
        p.toValue.targets)))
  newSend[Q, A](send, denote)