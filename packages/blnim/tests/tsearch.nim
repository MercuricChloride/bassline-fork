## search: searches, and the denoted spaces that interpreting turns back
## into searches whose answers are rebuilt from their values

import std/[unittest, options]
import bl/core
import bl/lib/blmacro
import bl/queries

template refuses(call: untyped) =
  expect ValueError:
    discard call

type Peer = ref object
  ## a runtime thing with a denotation: its address is a value, its
  ## connection is not
  address: string
  connection: int   # stands in for a live connection

var connections = 0

proc toValue(p: Peer): Value =
  bl peer({address: %p.address})

proc fromValue(T: typedesc[Peer], v: Value): Peer =
  ## rebuilds a peer from its value, connecting again
  if v.kind != bRec or v.mark or v.items.len != 2 or v.head != bl(peer) or
      v.items[1].kind != bDict or bl(address) notin v.items[1].dict:
    raise newException(ValueError, "not a peer: " & $v)
  let address = v.items[1].dict[bl address]
  if address.kind != bText:
    raise newException(ValueError, "an address is text: " & $v)
  inc connections
  Peer(address: address.text, connection: connections)

suite "interpreting a space":
  test "a set space answers a query with every record headed by it":
    let s = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(s1), holds({alice(1), alice(2), bob(3), (carol)})})
    check s.ask(bl alice).collect == @[bl 1, bl 2]
    check s.ask(bl bob).collect == @[bl 3]
    check s.ask(bl dave).collect.len == 0

  test "a query that is itself a record heads its records":
    let s = Search[Value, Value].fromValue readValue(
      "!{!(kind search-space) (identity s1) (holds {((f x) 1) ((f y) 2)})}")
    check s.ask(bl f(x)).collect == @[bl 1]
    check s.ask(bl f).collect.len == 0

  test "a question, (q) alone, sits with q's answers and isn't one":
    let s = Search[Value, Value].fromValue readValue(
      "!{!(kind search-space) (identity s1) (holds {(k 1) (k) (k 2) (j)})}")
    check s.ask(bl k).collect == @[bl 1, bl 2]
    check s.ask(bl j).collect.len == 0
    let ranked = Search[Value, Ranked[Value]].fromValue readValue(
      "!{!(kind search-space) !(kind ranked) (identity s2) (holds {(k 0 a) (k)})}")
    check ranked.ask(bl k).collect.len == 1

  test "a dict space answers at most once":
    let s = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(s1), holds({k: v})})
    check s.ask(bl k).collect == @[bl v]
    check s.ask(bl j).collect.len == 0

  test "a ranked space answers lowest rank first, ranks read as numbers":
    let s = Search[Value, Ranked[Value]].fromValue bl(
      !{!kind(`search-space`), !kind(ranked), identity(s2), holds({k(10, ten), k(2, two), k(0, zero), j(1, x)})})
    var got: seq[(int, Value)]
    for r in s.ask(bl k): got.add (r.rank, r.answer)
    check got == @[(0, bl zero), (2, bl two), (10, bl ten)]

  test "kinds compose: a ranked cat is read as ranked and as a cat":
    let ranked = Search[Value, Ranked[Value]].fromValue readValue(
      "!{!(kind search-space) !(kind ranked) !(kind cat) (identity rc) (parts [" &
      "!{!(kind search-space) !(kind ranked) (identity a) (holds {(k 1 x)})} " &
      "!{!(kind search-space) !(kind ranked) (identity b) (holds {(k 0 y)})}])}")
    var got: seq[Value]
    for r in ranked[bl k]: got.add r.answer
    check got == @[bl x, bl y]                 # a cat: the first part, then the next
    let written = merge([Search[Value, Ranked[Value]].fromValue readValue(
      "!{!(kind search-space) !(kind ranked) (identity a) (holds {})}")], id = bl m).toValue
    check written.hasKind(RankedKind)          # a ranked composite says so
    refuses Search[Value, Value].fromValue readValue(
      "!{!(kind search-space) !(kind cat) !(kind alt) (identity x) (parts [])}")
    refuses Search[Value, Value].fromValue readValue(
      "!{!(kind search-space) !(kind sparkly) (identity x) (holds {})}")

  test "several holds are all answered from, in turn":
    let s = Search[Value, Value].fromValue readValue(
      "!{!(kind search-space) (identity s) (holds {(a 1)}) (holds {(a 2)})}")
    check s[bl a].collect == @[bl 1, bl 2]
    check s.toValue == readValue(
      "!{!(kind search-space) (identity s) (holds {(a 1)}) (holds {(a 2)})}")

  test "several ranked holds, or parts, are merged by rank":
    var got: seq[int]
    for r in Search[Value, Ranked[Value]].fromValue(readValue(
        "!{!(kind search-space) !(kind ranked) (identity s) " &
        "(holds {(k 0 x) (k 9 y)}) (holds {(k 5 z)})}"))[bl k]:
      got.add r.rank
    check got == @[0, 5, 9]
    got.setLen 0
    for r in Search[Value, Ranked[Value]].fromValue(readValue(
        "!{!(kind search-space) !(kind ranked) !(kind merge) (identity m) " &
        "(parts [!{!(kind search-space) !(kind ranked) (holds {(k 0 x) (k 9 y)})}]) " &
        "(parts [!{!(kind search-space) !(kind ranked) (holds {(k 5 z)})}])}"))[bl k]:
      got.add r.rank
    check got == @[0, 5, 9]

  test "a ranked space is for ranked answers, the others for the rest":
    refuses Search[Value, Value].fromValue bl(!{!kind(`search-space`), !kind(ranked), identity(s), holds({})})
    refuses Search[Value, Ranked[Value]].fromValue bl(!{!kind(`search-space`), identity(s), holds({})})
    refuses Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(s)})
    refuses Search[Value, Value].fromValue bl({!kind(`search-space`), identity(s), holds({})})
    refuses Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(s), holds([k(1)])})

  test "the search written down again is the space it was read from":
    let space = bl(!{!kind(`search-space`), identity(s1), holds({a(1), b(2)})})
    check Search[Value, Value].fromValue(space).toValue == space

suite "refusals":
  let space = bl(!{!kind(`search-space`), identity(s), holds({p(peer({address: "a"})), p(nonsense),
                                    p(peer({address: "b"}))})})

  test "a refused answer raises":
    let s = Search[Value, Peer].fromValue(space)
    refuses s.ask(bl p).collect

  test "skipRefused passes over it":
    let s = Search[Value, Peer].fromValue(space, skipRefused = true)
    var addresses: seq[string]
    for peer in s.ask(bl p): addresses.add peer.address
    check addresses == @["a", "b"]

  test "a record the space can't hold is a refusal too":
    let odd = bl(!{!kind(`search-space`), identity(s), holds({k(1, 2), k(3)})})
    refuses Search[Value, Value].fromValue(odd).ask(bl k).collect
    check Search[Value, Value].fromValue(odd, skipRefused = true).ask(
      bl k).collect == @[bl 3]
    let badRank = bl(!{!kind(`search-space`), !kind(ranked), identity(s), holds({k(-1, a), k(x, b), k(0, c)})})
    refuses Search[Value, Ranked[Value]].fromValue(badRank).ask(bl k).collect
    var got: seq[Value]
    for r in Search[Value, Ranked[Value]].fromValue(badRank,
        skipRefused = true).ask(bl k):
      got.add r.answer
    check got == @[bl c]

suite "denoting":
  test "a search with no denotation refuses to be written down":
    let s = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      initStream(@[q]))
    check not s.denotable
    refuses s.toValue

  test "an id is had without writing the search down":
    var written = 0
    let s = newSearch[Value, Value](
      proc(q: Value): Stream[Value] = empty[Value](),
      proc(): Value =
        inc written
        bl(!{!kind(`search-space`), identity(p), holds({})}),
      proc(): Value = bl p)
    check s.id == bl p
    check s.byId.toValue == bl p
    check cat([s.byId], id = bl c).toValue == bl(!{!kind(`search-space`), !kind(cat), identity(c), parts([p])})
    check written == 0
    check cat([s], id = bl c).id == bl c
    check Search[Value, Value].fromValue(bl(!{!kind(`search-space`), identity(q), holds({})})).id == identity(bl q)   # its names, as an object

  test "without an id proc, the id is read from the denotation":
    let s = newSearch[Value, Value](
      proc(q: Value): Stream[Value] = empty[Value](),
      proc(): Value = bl(!{!kind(`search-space`), identity(p2), holds({})}))
    check s.id == identity(bl p2)
    let plain = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      empty[Value]())
    refuses plain.id

suite "a peer table":
  test "peers are written down by address and rebuilt, connected again":
    let table = @[Peer(address: "10.0.0.1", connection: -1),
                  Peer(address: "10.0.0.2", connection: -1)]
    proc live(q: Value): Stream[Peer] =
      initStream(if q == bl(peers): table else: @[])
    proc written(): Value =
      var space = newBSet()
      for p in table: space.incl initRec(@[bl(peers), p.toValue])
      describe([SearchSpaceKind], bl here, initRec(@[HoldsQ, initSet(space)]))
    let saved = newSearch[Value, Peer](live, written).toValue
    let before = connections
    var back: seq[Peer]
    for p in Search[Value, Peer].fromValue(saved).ask(bl peers): back.add p
    check back.len == 2
    check back[0].address == "10.0.0.1" and back[1].address == "10.0.0.2"
    check back[0] != table[0]                     # new objects
    check connections == before + 2               # connected again

suite "composing":
  let
    parent = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(p1), holds({x(1), y(2)})})
    child = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(c1), holds({x(10)})})

  test "a scope answers first, then the scope around it":
    let scope = cat([child, parent], id = bl s)
    check scope.ask(bl x).collect == @[bl 10, bl 1]  # the first is the shadow
    check scope.ask(bl x)[] == some(bl 10)           # the consumer takes it
    check scope.ask(bl y).collect == @[bl 2]

  test "the scope around is asked only once the inner one runs out":
    var asked = 0
    let outer = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      inc asked
      initStream(@[bl outer]))
    let scope = cat([child, outer])
    check scope.ask(bl x).take(1) == @[bl 10]
    check asked == 0
    check scope.ask(bl x).collect == @[bl 10, bl outer]
    check asked == 1

  test "written down, it carries the scope around it whole":
    let scope = cat([child, parent], id = bl s)
    check scope.toValue == bl(!{!kind(`search-space`), !kind(cat), identity(s), parts([!{!kind(`search-space`), identity(c1), holds({x(10)})},
                                              !{!kind(`search-space`), identity(p1), holds({x(1), y(2)})}])})
    check Search[Value, Value].fromValue(scope.toValue).ask(bl x).collect ==
      @[bl 10, bl 1]

  test "or names it, and a search of known spaces resolves the name":
    let scope = cat([child, parent.byId], id = bl s)
    let written = scope.toValue
    check written == bl(!{!kind(`search-space`), !kind(cat), identity(s), parts([!{!kind(`search-space`), identity(c1), holds({x(10)})}, !{identity(p1)}])})
    refuses Search[Value, Value].fromValue(written)   # nothing to resolve p1
    let known = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(known), holds({p1: !{!kind(`search-space`), identity(p1), holds({x(1), y(2)})}})})
    let back = Search[Value, Value].fromValue(written, resolve = known)
    check back.ask(bl x).collect == @[bl 10, bl 1]
    check back.ask(bl y).collect == @[bl 2]
    check back.toValue == written                   # still by name

  test "a name is resolved when asked, so it sees what is known by then":
    var spaces: seq[Value]
    let known = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      initStream(if q == bl(p1): spaces else: @[]))
    let back = Search[Value, Value].fromValue(
      bl(!{!kind(`search-space`), !kind(cat), identity(s), parts([!{!kind(`search-space`), identity(c1), holds({x(10)})}, !{identity(p1)}])}), resolve = known)
    check back.ask(bl y).collect.len == 0
    spaces.add bl(!{!kind(`search-space`), identity(p1), holds({y(2)})})
    spaces.add bl(!{!kind(`search-space`), identity(p1b), holds({y(3)})})       # two spaces by one name
    check back.ask(bl y).collect == @[bl 2, bl 3]

  test "an identity names a space by several names, any of which finds it":
    let id = identity(bl p1, bl `old-p1`, bl(digest(sha256, 0x00)))
    check id == bl(!{identity(p1), identity(`old-p1`), identity(digest(sha256, 0x00))})
    check identities(id).collect.len == 3
    check identities(bl p1).collect == @[bl p1]
    let known = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(known), holds({`old-p1`: !{!kind(`search-space`), identity(p1), holds({y(2)})}})})
    let back = Search[Value, Value].fromValue(
      describe([SearchSpaceKind, CatKind], bl s, initRec(@[PartsQ, initList(@[bl(!{!kind(`search-space`), identity(c1), holds({x(10)})}), id])])),
      resolve = known)
    check back.ask(bl y).collect == @[bl 2]
    check back.toValue.answer(PartsQ).get.items[1] == id   # still the names

  test "identities are sets: sameness is meeting, a new name is a union":
    let a = identity(bl peers, bl "https://example.org/peers")
    let b = identity(bl(digest(sha256, 0x01)), bl peers)
    check sharesIdentity(a, b)
    check not sharesIdentity(a, identity(bl other))
    check sharesIdentity(bl peers, a)             # a bare ID is a set of one
    let both = a.alsoKnownAs(b, bl `peers-v2`)
    check identities(both).collect.len == 4
    check both.isObject and both.kinds.collect.len == 0   # only names
    check randomId().isObject
    check randomId() != randomId()

  test "names that lead round to themselves come to an end":
    let space = bl(!{!kind(`search-space`), identity(p3), holds({y(2)})})
    let known = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      if q == bl(p1): just(identity(bl p2))
      elif q == bl(p2): initStream(@[identity(bl p1), space])
      else: empty[Value]())
    let back = Search[Value, Value].fromValue(identity(bl p1), resolve = known)
    check back[bl y].collect == @[bl 2]

  test "an object of a kind that isn't a search is not names of one":
    refuses Search[Value, Value].fromValue(bl(!{!kind(send), !to(p)}))

  test "a space found under two names answers once":
    let space = bl(!{!kind(`search-space`), identity(p1), holds({y(2)})})
    let known = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      initStream(@[space]))                          # every name finds it
    let back = Search[Value, Value].fromValue(identity(bl a, bl b),
                                              resolve = known)
    check back.ask(bl y).collect == @[bl 2]

  test "alt takes turns":
    let a = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(a), holds({k(1), k(2), k(3)})})
    let b = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(b), holds({k(10), k(20)})})
    check alt([a, b]).ask(bl k).collect == @[bl 1, bl 10, bl 2, bl 20, bl 3]

  test "feed asks the second search about each answer of the first":
    let friends = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(f), holds({alice(bob), alice(carol)})})
    let scores = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(g), holds({bob(1), carol(2), carol(3)})})
    let both = feed(friends, scores, id = bl fs)
    check both.ask(bl alice).collect == @[bl 1, bl 2, bl 3]
    check both.toValue == bl(!{!kind(`search-space`), !kind(feed), identity(fs), parts([!{!kind(`search-space`), identity(f), holds({alice(bob), alice(carol)})}, !{!kind(`search-space`), identity(g), holds({bob(1), carol(2), carol(3)})}])})
    check Search[Value, Value].fromValue(both.toValue).ask(bl alice).collect ==
      @[bl 1, bl 2, bl 3]

  test "merge interleaves ranked searches by rank":
    let a = Search[Value, Ranked[Value]].fromValue bl(
      !{!kind(`search-space`), !kind(ranked), identity(a), holds({k(0, a0), k(5, a5)})})
    let b = Search[Value, Ranked[Value]].fromValue bl(
      !{!kind(`search-space`), !kind(ranked), identity(b), holds({k(1, b1), k(5, b5), k(9, b9)})})
    let m = merge([a, b], id = bl m)
    var got: seq[Value]
    for r in m.ask(bl k): got.add r.answer
    check got == @[bl a0, bl b1, bl a5, bl b5, bl b9]
    var again: seq[Value]
    for r in Search[Value, Ranked[Value]].fromValue(m.toValue).ask(bl k):
      again.add r.answer
    check again == got
    refuses Search[Value, Value].fromValue(m.toValue)  # merge is for ranks

  test "a composite with a part that has no denotation has none":
    let plain = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      initStream(@[q]))
    check not cat([child, plain]).denotable
    check not feed(child, plain).denotable
    check cat([child, plain]).ask(bl x).collect == @[bl 10, bl x]

suite "fan-out":
  let
    dict = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(d), holds({a: 1, b: 2})})
    setSpace = Search[Value, Value].fromValue bl(!{!kind(`search-space`), identity(s), holds({a(1), a(2)})})

  test "a dict space has one answer a query, a set space any number":
    check dict.fanout == one
    check setSpace.fanout == many

  test "a search made with one answer a query stops after the first":
    let s = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      initStream(@[bl first, bl second]), fanout = one)
    check s.ask(bl q).collect == @[bl first]

  test "composites: a feed of two single searches is single, the rest many":
    check feed(dict, dict).fanout == one
    check feed(dict, setSpace).fanout == many
    check cat([dict, dict]).fanout == many
    check alt([dict]).fanout == many
    check dict.byId.fanout == one

  test "an id can be given as a value":
    let s = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      empty[Value](), id = bl named)
    check s.id == bl named
