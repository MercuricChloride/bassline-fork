## bvar: a place to put values and search what has been put; memoising
## a search into one; keeping one in a file

import std/[unittest, options, os]
import bl/core
import bl/lib/[blmacro, bvarfile]
import bl/queries/bvar

template refuses(call: untyped) =
  expect ValueError:
    discard call

type Peer = ref object
  ## a runtime thing: its address is a value, its connection is not
  address: string
  connection: int

var connections = 0

proc toValue(p: Peer): Value =
  bl peer(%p.address)

proc fromValue(T: typedesc[Peer], v: Value): Peer =
  if v.kind != bRec or v.items.len != 2 or v.head != bl(peer) or
      v.items[1].kind != bText:
    raise newException(ValueError, "not a peer: " & $v)
  inc connections
  Peer(address: v.items[1].text, connection: connections)

suite "space vars":
  test "what is sent is kept as a search set, and reading asks it":
    let v = spaceVar[Value, Value](id = bl v)
    check v.send(bl alice, bl 1)
    check v.send(bl alice, bl 2)
    check v.send(bl bob, bl 3)
    check v.read(bl alice).collect == @[bl 1, bl 2]
    check v.read(bl carol).collect.len == 0
    check v.search.toValue == bl(!{!kind(`search-space`), identity(v), holds({alice(1), alice(2), bob(3)})})

  test "runtime things are sent, kept as values, and read back as things":
    let v = spaceVar[Value, Peer](id = bl peers)
    check v.send(bl here, Peer(address: "10.0.0.1", connection: -1))
    check v.search.toValue == bl(!{!kind(`search-space`), identity(peers), holds({here(peer("10.0.0.1"))})})
    let back = v.read(bl here)[]
    check back.isSome and back.get.address == "10.0.0.1"
    check back.get.connection > 0                # rebuilt, connected again

  test "a read with nothing asked asks nil":
    let v = spaceVar[Value, Value]()
    check v.send(null(), bl anything)
    check v.read().collect == @[bl anything]

  test "with one answer a query, the first answer sent stands":
    let v = spaceVar[Value, Value](one, id = bl d)
    check v.send(bl x, bl 1)
    check v.send(bl x, bl 1)                   # the same again is taken
    check not v.send(bl x, bl 2)               # a second answer is not
    check v.read(bl x).collect == @[bl 1]
    check v.search.toValue == bl(!{!kind(`search-space`), identity(d), holds({x: 1})})

  test "a ranked var reads back in rank order":
    let v = spaceVar[Value, Ranked[Value]](id = bl r)
    check v.send(bl k, Ranked[Value](rank: 5, answer: bl late))
    check v.send(bl k, Ranked[Value](rank: 0, answer: bl soon))
    var got: seq[Value]
    for a in v.read(bl k): got.add a.answer
    check got == @[bl soon, bl late]

  test "written down, it is what it held then, and stays so":
    let v = spaceVar[Value, Value](id = bl v)
    discard v.send(bl a, bl 1)
    let then = v.search.toValue
    discard v.send(bl a, bl 2)
    check then == bl(!{!kind(`search-space`), identity(v), holds({a(1)})})
    check v.search.toValue == bl(!{!kind(`search-space`), identity(v), holds({a(1), a(2)})})

  test "a space written down is held again, as a copy":
    let space = bl(!{!kind(`search-space`), identity(old), holds({a(1)})})
    let v = spaceVar[Value, Value](space)
    discard v.send(bl a, bl 2)
    check v.read(bl a).collect == @[bl 1, bl 2]
    check v.search.id == identity(bl old)
    check space == bl(!{!kind(`search-space`), identity(old), holds({a(1)})})   # the value unchanged
    check spaceVar[Value, Value](bl(!{!kind(`search-space`), identity(d), holds({x: 1})})).search.fanout == one
    refuses spaceVar[Value, Value](bl junk)
    refuses spaceVar[Value, Ranked[Value]](space)

  test "a space holding several dicts is held as every record it holds":
    let v = spaceVar[Value, Value](readValue(
      "!{!(kind search-space) (identity d) (holds {x: 1}) (holds {x: 2}) (holds {(x 3)})}"))
    check v[bl x].collect == @[bl 1, bl 2, bl 3]
    check v.search.fanout == many

  test "what a holder can do is which halves it has":
    let v = spaceVar[Value, Value]()
    check v.access == Access.rw
    check v.readOnly.access == Access.r
    check v.writeOnly.access == Access.w
    check newBVar[Value, Value]().access == Access.none
    check not v.readOnly.send(bl a, bl 1)
    check v.writeOnly.send(bl a, bl 1)
    refuses v.writeOnly.read(bl a)
    check v.readOnly.read(bl a).collect == @[bl 1]

suite "written down":
  test "a space var: its send into the space, and the space":
    let v = spaceVar[Value, Value](id = bl v)
    discard v.send(bl a, bl 1)
    check v.toValue == bl(!{!kind(bvar), identity(v), send(!{!kind(send), !to(v)}), search(!{!kind(`search-space`), identity(v), holds({a(1)})})})
    check v.readOnly.toValue == bl(!{!kind(bvar), identity(v), search(!{!kind(`search-space`), identity(v), holds({a(1)})})})
    check v.writeOnly.toValue == bl(!{!kind(bvar), identity(v), send(!{!kind(send), !to(v)})})

  test "read back, a space with a send into it is a live space var":
    let v = spaceVar[Value, Value](id = bl v)
    discard v.send(bl a, bl 1)
    let back = BVar[Value, Value].fromValue(v.toValue)
    check back.access == Access.rw
    check back.send(bl a, bl 2)
    check back.read(bl a).collect == @[bl 1, bl 2]
    check v.read(bl a).collect == @[bl 1]       # a copy, not the same place

  test "a read-only one reads back read-only":
    let v = spaceVar[Value, Value](id = bl v)
    discard v.send(bl a, bl 1)
    let back = BVar[Value, Value].fromValue(v.readOnly.toValue)
    check back.access == Access.r
    check back.read(bl a).collect == @[bl 1]

  test "a write-only one reaches the place the environment knows by it":
    let v = spaceVar[Value, Value](id = bl v)
    let resolve = newSearch[Value, Send[Value, Value]](
      proc(d: Value): Stream[Send[Value, Value]] =
        initStream(if sharesIdentity(d, bl v): @[v.sender] else: @[]))
    let back = BVar[Value, Value].fromValue(v.writeOnly.toValue, resolve)
    check back.access == Access.w
    check back.send(bl a, bl 9)
    check v.read(bl a).collect == @[bl 9]

  test "a bvar whose send has no denotation can't be written down":
    let v = newBVar[Value, Value](proc(q, a: Value): bool = true)
    refuses v.toValue
    refuses BVar[Value, Value].fromValue(bl junk)

suite "reading back, every answer":
  test "a send to several places reaches all of them, the live copy as one":
    let v1 = spaceVar[Value, Value](id = bl v1)
    let v2 = spaceVar[Value, Value](id = bl v2)
    let b = newBVar(tee([v1.sender, v2.sender]), v1.search, id = bl b)
    var asked: seq[Value]
    let resolve = newSearch[Value, Send[Value, Value]](
      proc(n: Value): Stream[Send[Value, Value]] =
        asked.add n
        initStream(if n == bl(v2): @[v2.sender] else: @[]))
    let back = BVar[Value, Value].fromValue(b.toValue, resolve)
    check back.send(bl k, bl 1)
    check v2[bl k].collect == @[bl 1]            # the other target, resolved
    check back[bl k].collect == @[bl 1]          # and the live copy of v1
    check bl(v1) in asked and bl(v2) in asked  # every target was asked about

  test "a target with several names is resolved by each of them":
    let v = spaceVar[Value, Value](id = bl n1)
    let resolve = newSearch[Value, Send[Value, Value]](
      proc(n: Value): Stream[Send[Value, Value]] =
        initStream(if n == bl(n1): @[v.sender] else: @[]))
    let w = BVar[Value, Value].fromValue(
      bl(!{!kind(bvar), identity(w), send(!{!kind(send), !to(!{identity(n1), identity(n2)})})}),
      resolve)
    check w.send(bl k, bl 1)
    check v[bl k].collect == @[bl 1]

  test "several sends tell every one; several searches are all asked":
    let (a, b) = (spaceVar[Value, Value](id = bl a), spaceVar[Value, Value](id = bl b))
    discard a.send(bl k, bl 1)
    discard b.send(bl k, bl 2)
    let both = bl(!{!kind(bvar), identity(ab),
      search(!{!kind(`search-space`), identity(a), holds({k(1)})}),
      search(!{!kind(`search-space`), identity(b), holds({k(2)})})})
    check BVar[Value, Value].fromValue(both)[bl k].collect == @[bl 1, bl 2]

  test "a space holding several bodies holds them all":
    let v = spaceVar[Value, Value](bl(!{!kind(`search-space`), identity(s),
      holds({a(1)}), holds({a(2)})}))
    check v[bl a].collect == @[bl 1, bl 2]

suite "streams over a place that grows":
  test "an open stream survives the place growing, and sees what comes after":
    let v = spaceVar[Value, Value](id = bl v)
    for i in 0 ..< 40: discard v.send(bl k, toValue(i * 2))   # even
    let early = v[bl k]
    var got: seq[Value]
    for _ in 0 ..< 35: got.add early().get   # well into one leaf
    for i in 0 ..< 200: discard v.send(bl k, toValue(1001 + i * 2))  # splits it
    var rest = 0
    for x in early: inc rest
    check got[34] == bl 68
    check rest == 5 + 200                      # the rest, and all that came after

suite "subscripts":
  test "subscripting a bvar or search gives every answer; ? the first":
    let v = spaceVar[Value, Value](id = bl v)
    discard v.send(bl k, bl 1)
    discard v.send(bl k, bl 2)
    check v[bl k].collect == @[bl 1, bl 2]
    check (v ? bl(k)) == some(bl 1)
    check (v ? bl(nothing)).isNone
    check v.search[bl k].collect == @[bl 1, bl 2]
    check (v.search ? bl(k)) == some(bl 1)

suite "many places as one":
  test "a union tells every part and reads them all, taking turns":
    let (a, b) = (spaceVar[Value, Value](id = bl a), spaceVar[Value, Value](id = bl b))
    discard a.send(bl k, bl 1)
    discard b.send(bl k, bl 2)
    let u = union([a, b.readOnly])
    check u[bl k].collect == @[bl 1, bl 2]
    check u.send(bl k, bl 3)                   # only a can be sent to
    check a[bl k].collect == @[bl 1, bl 3]
    check b[bl k].collect == @[bl 2]

suite "keeping":
  test "a send the keeper couldn't keep wasn't taken":
    let v = spaceVar[Value, Value]().persist(proc(space: Value): bool = false)
    check not v.send(bl a, bl 1)
    check v[bl a].collect == @[bl 1]              # held, though not kept

  test "only a place that can be sent to and written down is kept":
    let keep = proc(space: Value): bool = true
    refuses spaceVar[Value, Value]().writeOnly.persist(keep)
    refuses spaceVar[Value, Value]().readOnly.persist(keep)
    refuses newBVar[Value, Value](proc(q, a: Value): bool = true,
      newSearch[Value, Value](proc(q: Value): Stream[Value] = empty[Value]())).persist(keep)

  test "persist hands over the space, written down, each time it takes":
    var kept: seq[Value]
    let v = spaceVar[Value, Value](one, id = bl k).persist(
      proc(space: Value): bool =
        kept.add space
        true)
    check v.send(bl a, bl 1)
    check not v.send(bl a, bl 2)                # not taken: nothing kept
    check v.send(bl b, bl 2)
    check kept == @[bl(!{!kind(`search-space`), identity(k), holds({a: 1})}),
                    bl(!{!kind(`search-space`), identity(k), holds({a: 1, b: 2})})]

suite "memo":
  test "it keeps what it has answered, and writes that down":
    let pulls = new int
    let s = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      var n = 0
      proc(): Option[Value] =
        inc pulls[]
        inc n
        if n <= 3: some initList(@[q, toValue(n)]) else: none(Value))
    let m = s.memo(id = bl s9)
    check m.ask(bl a).take(2) == @[bl [a, 1], bl [a, 2]]
    check pulls[] == 2
    check m.toValue == bl(!{!kind(`search-space`), identity(s9), holds({a([a, 1]), a([a, 2])})})
    discard m.ask(bl b).collect
    let again = Search[Value, Value].fromValue(m.toValue)
    check again.ask(bl b).collect == @[bl [b, 1], bl [b, 2], bl [b, 3]]
    check again.ask(bl a).collect == @[bl [a, 1], bl [a, 2]]

  test "asked again, it answers from what it kept first, then what is new":
    let s = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      initStream(@[bl 1, bl 2, bl 3]))
    let m = s.memo(id = bl m)
    check m.ask(bl a).take(1) == @[bl 1]
    check m.ask(bl a).collect == @[bl 1, bl 2, bl 3]   # 1 kept, not twice
    check m.toValue == bl(!{!kind(`search-space`), identity(m), holds({a(1), a(2), a(3)})})

  test "with one answer a query, a kept answer is not asked for again":
    var asked = 0
    let s = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      inc asked
      initStream(@[bl answer]), fanout = one)
    let m = s.memo(id = bl m)
    check m.ask(bl a).collect == @[bl answer]
    check m.ask(bl a).collect == @[bl answer]
    check asked == 1
    check m.toValue == bl(!{!kind(`search-space`), identity(m), holds({a: answer})})
    check m.fanout == one
    check Search[Value, Value].fromValue(m.toValue).fanout == one

  test "a ranked memo keeps the ranks":
    let s = newSearch[Value, Ranked[Value]](proc(q: Value): Stream[Ranked[Value]] =
      initStream(@[Ranked[Value](rank: 1, answer: bl late),
                   Ranked[Value](rank: 0, answer: bl soon)]))
    let m = s.memo(id = bl r)
    discard m.ask(bl k).collect
    check m.toValue == bl(!{!kind(`search-space`), !kind(ranked), identity(r), holds({k(0, soon), k(1, late)})})

  test "a ranked memo answers in rank order, however the search grew":
    let src = spaceVar[Value, Ranked[Value]]()
    discard src.send(bl q, Ranked[Value](rank: 1, answer: bl b))
    discard src.send(bl q, Ranked[Value](rank: 2, answer: bl c))
    let m = src.search.memo
    check m[bl q][].get.rank == 1               # kept
    discard src.send(bl q, Ranked[Value](rank: 0, answer: bl a))
    var ranks: seq[int]
    for r in m[bl q]: ranks.add r.rank
    check ranks == @[0, 1, 2]

  test "a memo without an id gets a random one":
    let m = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      empty[Value]()).memo
    let id = m.id
    check id.isObject                          # !{(identity 0x…)}
    let names = identities(id).collect
    check names.len == 1 and names[0].bytes.len == 16

suite "file vars":
  let dir = getTempDir() / ("tbvar-" & $getCurrentProcessId())
  setup:
    removeDir(dir)
    createDir(dir)
  teardown:
    removeDir(dir)

  test "the file holds one value: the space, as it stands":
    let path = dir / "v.blb"
    let v = fileVar[Value, Value](path, id = bl peers)
    check valueIn(path) == bl(!{!kind(`search-space`), identity(peers), holds({})})
    check v.send(bl alice, bl 1)
    check v.send(bl bob, bl 2)
    check valueIn(path) == bl(!{!kind(`search-space`), identity(peers), holds({alice(1), bob(2)})})

  test "opened again, it holds what it held, by its own name":
    let path = dir / "v.blb"
    discard fileVar[Value, Value](path, one, id = bl settings).send(bl x, bl 1)
    let v = fileVar[Value, Value](path)          # id and fan-out from the file
    check v.read(bl x).collect == @[bl 1]
    check v.search.id == identity(bl settings)
    check v.search.fanout == one
    check not v.send(bl x, bl 2)                 # the first answer stands

  test "a file that isn't one space is refused":
    let junk = dir / "junk.blb"
    check writeValue(junk, bl junk)
    refuses fileVar[Value, Value](junk)
    let two = dir / "two.blb"
    writeFile(two, ce(bl(!{!kind(`search-space`), identity(a), holds({})})).toString & ce(bl x).toString)
    refuses fileVar[Value, Value](two)
    let plain = dir / "plain.blb"
    discard fileVar[Value, Value](plain)
    refuses fileVar[Value, Ranked[Value]](plain)   # unranked, read as ranked

  test "a memo over a file var persists and comes back":
    let path = dir / "memo.blb"
    var asked = 0
    let slow = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      inc asked
      initStream(@[initList(@[q, bl found])]), fanout = one)
    discard slow.memo(fileVar[Value, Value](path, one, id = bl cache)).ask(
      bl a).collect
    check asked == 1
    let later = slow.memo(fileVar[Value, Value](path))   # another run
    check later.ask(bl a).collect == @[bl [a, found]]
    check asked == 1                                     # from the file