## send: what you tell, as an object like a search; read back by a
## search from denotations to sends

import std/unittest
import bl/core
import bl/lib/blmacro
import bl/queries

template refuses(call: untyped) =
  expect ValueError:
    discard call

proc collecting(into: ref seq[(Value, Value)], taking = true): Send[Value, Value] =
  newSend[Value, Value](proc(q, a: Value): bool =
    if taking: into[].add (q, a)
    taking)

suite "send":
  test "a send says whether it took what it was told":
    let got = new seq[(Value, Value)]
    check collecting(got).send(bl q, bl a)
    check got[] == @[(bl q, bl a)]
    check not collecting(got, taking = false).send(bl q, bl b)

  test "written down only if it has a denotation, by what it sends to":
    let s = newSend[Value, Value](proc(q, a: Value): bool = true,
      k(bl(!{!kind(send), !to(p)})))
    check s.toValue == bl(!{!kind(send), !to(p)})
    refuses newSend[Value, Value](proc(q, a: Value): bool = true).toValue

  test "a tee tells every part, taken if any took it":
    let (a, b) = (new seq[(Value, Value)], new seq[(Value, Value)])
    let t = tee([collecting(a), collecting(b, taking = false)])
    check t.send(bl q, bl 1)
    check a[] == @[(bl q, bl 1)]
    check not tee([collecting(b, taking = false)]).send(bl q, bl 2)
    check not t.denotable                      # its parts have no denotation

  test "a tee written down sends to everything its parts send to":
    let into = proc(id: Value): Send[Value, Value] =
      newSend[Value, Value](proc(q, a: Value): bool = true, k(sendTo(id)))
    check sendTo(bl a) == bl(!{!kind(send), !to(a)})
    check tee([into(bl a), into(bl b)]).toValue == bl(!{!kind(send), !to(a), !to(b)})

suite "sends read back":
  test "reading a send back is a search from identities to sends":
    let here = new seq[(Value, Value)]
    var known: seq[Send[Value, Value]]
    let reach = newSearch[Value, Send[Value, Value]](
      proc(d: Value): Stream[Send[Value, Value]] =
        initStream(if d == bl(p): known else: @[]))
    check reach.ask(bl p).collect.len == 0   # nothing yet
    known.add collecting(here)
    for s in reach.ask(bl p):
      check s.send(bl q, bl 2)
    check here[] == @[(bl q, bl 2)]
