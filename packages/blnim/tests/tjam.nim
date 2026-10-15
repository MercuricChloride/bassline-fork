## jam: answers put and questions asked, told to whoever asks

import std/[options, os, sequtils, sets, unittest]
import bl/[core, queries]
import bl/queries/rewrite
import bl/lib/[blmacro, bvarfile, jam]
import bl/lib/crypto/[clave, digest]

proc listener(): (ref seq[Value], (Value) -> bool) =
  ## a line's telling, kept to look at
  let told = new seq[Value]
  (told, (v: Value) => (block:
    told[].add v
    true))

proc memoryJam(signedOnly = false, passes: openArray[string] = []): Jam =
  newJam(spaceVar[Value, Ranked[Value]](), signedOnly,
         passes = passes.mapIt(rewrite.Shape.fromValue(rv(it))))

proc seed(n: byte): Keypair =
  var s: Seed
  for i in 0 ..< 32: s[i] = n
  keypairFromSeed(s)

suite "a jam":
  test "what is put is told to whoever asks, what it has and then as it comes":
    let jam = memoryJam()
    let (_, a) = listener()
    let (told, b) = listener()
    let (alice, bob) = (jam.newLine(a), jam.newLine(b))
    check jam.hear(alice, bl(general("hi")))
    check jam.hear(bob, bl(general()))
    check told[] == @[bl(general(1, "hi"))]       # 0 is the jam's own (jam)
    check jam.hear(alice, bl(general("anyone?")))
    check jam.hear(alice, bl(random("elsewhere")))
    check told[] == @[bl(general(1, "hi")), bl(general(2, "anyone?"))]

  test "an answer put twice is kept once, and asking twice tells once":
    let jam = memoryJam()
    let (told, t) = listener()
    let line = jam.newLine(t)
    check jam.hear(line, bl(q(a)))
    check jam.hear(line, bl(q(a)))
    check jam.hear(line, bl(q()))
    check jam.hear(line, bl(q()))
    check told[] == @[bl(q(1, a))]

  test "it reads neither questions nor answers, and refuses what is neither":
    let jam = memoryJam()
    let (told, t) = listener()
    let line = jam.newLine(t)
    check jam.hear(line, readValue("({alice bob} [1 2 {x: y}])"))
    check jam.hear(line, readValue("({alice bob})"))
    check told[] == @[readValue("({alice bob} 1 [1 2 {x: y}])")]
    check not jam.hear(line, bl(a(b, c)))       # three, not two
    check not jam.hear(line, bl(!q(a)))          # marked
    check not jam.hear(line, bl(hello))          # not a record

  test "signed answers are kept signed, so whoever is told can check them":
    let kp = seed(7)
    let jam = memoryJam(signedOnly = true)
    let (told, t) = listener()
    let line = jam.newLine(t)
    let alice = Speaker(name: bl alice, key: some kp)
    let said = alice.put(bl general, bl "signed hi")
    check jam.hear(line, said)
    check not jam.hear(line, bl(general("unsigned")))
    check jam.hear(line, alice.ask(bl general))
    check told[] == @[initRec(@[bl general, bl 1, said])]
    let h = heard(told[0]).get
    check h.said == bl("signed hi") and h.signer == some kp.pubkey
    var forged = said
    forged = initRec(@[forged.items[0], bl(general("changed")), forged.items[2]])
    check not jam.hear(line, forged)             # the signature doesn't hold

  test "it says which jam it is: its name, an id of its own and when it began":
    let jam = memoryJam()
    let (told, t) = listener()
    let line = jam.newLine(t)
    check jam.hear(line, bl(jam()))
    check told[].len == 1 and told[0].items[0] == JamQ and told[0].items[1] == bl 0
    let me = told[0].items[2]
    check me.knownAs(bl jam)
    check toSeq(me.identities).filterIt(it.kind == bBytes and it.bytes.len == 16).len == 1
    check me.answer(AtQ).isSome
    check not jam.hear(line, initRec(@[JamQ, bl "another jam"]))   # its own to say
    check told[].len == 1
    let (other, o) = listener()
    let another = newJam(spaceVar[Value, Ranked[Value]](), name = bl(bootstrap))
    check another.hear(another.newLine(o), bl(jam()))
    check other[0].items[2] != me and other[0].items[2].knownAs(bl bootstrap)

  test "a line that refuses a tell is dropped, and who it said was here is gone":
    let jam = memoryJam()
    let (seen, watch) = listener()
    let watcher = jam.newLine(watch)
    var taking = true
    let bob = jam.newLine(v => taking)
    check jam.hear(watcher, bl(gone()))
    check jam.hear(bob, initRec(@[HereQ, readValue("!{(by bob) (at 1)}")]))
    check jam.hear(bob, bl(general()))
    taking = false
    check jam.hear(watcher, bl(general("bob?")))  # bob refuses: dropped
    check seen[].len == 1 and heard(seen[0]).get.said.answer(ByQ) == some bl(bob)
    check not jam.hear(bob, bl(general("too late")))

  test "a line gone quiet is kept while it asks, and dropped when it doesn't":
    let jam = memoryJam()
    let (_, t) = listener()
    let (asking, quietOne) = (jam.newLine(t), jam.newLine(t))
    check jam.hear(asking, bl(q()))
    check jam.quiet(asking)
    check not jam.quiet(quietOne)

  test "a line gone quiet has left: who it said was here is gone at once":
    let jam = memoryJam()
    let (seen, watch) = listener()
    check jam.hear(jam.newLine(watch), bl(gone()))
    let (told, t) = listener()
    let bob = jam.newLine(t)
    check jam.hear(bob, initRec(@[HereQ, readValue("!{(by bob) (at 1)}")]))
    check jam.hear(bob, bl(general()))
    check jam.quiet(bob)                          # still told what it asks
    check seen[].len == 1 and heard(seen[0]).get.said.answer(ByQ) == some bl(bob)
    jam.drop(bob)
    check seen[].len == 1                         # gone once, not twice
    discard told

  test "a jam opened on a log says whoever it held as here is gone":
    let path = getTempDir() / "tjam-presence.blb"
    removeFile(path)
    defer: removeFile(path)
    block:
      let jam = newJam(logVar[Value, Ranked[Value]](path))
      let (_, t) = listener()
      check jam.hear(jam.newLine(t), initRec(@[HereQ, readValue("!{(by bob) (at 1)}")]))
    let again = newJam(logVar[Value, Ranked[Value]](path))
    let local = spaceVar[Value, Ranked[Value]]()
    for r in valuesIn(path): discard local.keep(r)
    check local.who.len == 0
    check toSeq(local.heardIn(GoneQ)).len == 1
    discard again

  test "kept in a log, opened again it holds what it held, ranks going on":
    let path = getTempDir() / "tjam-log.blb"
    removeFile(path)
    defer: removeFile(path)
    block:
      let jam = newJam(logVar[Value, Ranked[Value]](path))
      let (_, t) = listener()
      check jam.hear(jam.newLine(t), bl(general("first")))
    let again = newJam(logVar[Value, Ranked[Value]](path))
    let (told, t) = listener()
    let line = again.newLine(t)
    check again.hear(line, bl(general("first")))   # kept already
    check again.hear(line, bl(general("second")))
    check again.hear(line, bl(general()))
    check told[] == @[bl(general(1, "first")), bl(general(2, "second"))]
    let kept = valuesIn(path)
    check kept.len == 3 and kept[0].items[0] == JamQ and kept[0].items[1] == bl 0
    check kept[1 .. ^1] == @[bl(general(1, "first")), bl(general(2, "second"))]
    let (which, w) = listener()
    check again.hear(again.newLine(w), bl(jam()))   # the same jam as before
    check which[] == @[kept[0]]

  test "a log cut short partway through a record is cut back to the last whole one":
    let path = getTempDir() / "tjam-torn.blb"
    defer: removeFile(path)
    let whole = bl(general(0, "whole")).ce.toString
    writeFile(path, whole & bl(general(1, "torn")).ce.toString[0 .. 5])
    check valuesIn(path) == @[bl(general(0, "whole"))]
    check readFile(path) == whole

suite "readers":
  test "a reader keeps what it is told in its own space, and searches it":
    let local = spaceVar[Value, Ranked[Value]]()
    check local.keep(bl(general(3, "hi"))).get.rank == 3
    check local.keep(bl(general(5, "again"))).isSome
    check local.keep(bl(general(x, "not a rank"))).isNone
    check local.heardIn(bl general).maps(it.said).toSeq == @[bl "hi", bl "again"]

  test "messages say who, what and when, and what they answer and whom they are for":
    let alice = Speaker(name: bl alice)
    let first = heard(initRec(@[bl general, bl 0, alice.message(bl "hi")])).get
    let m = alice.message(bl "hi back", re = [first.digestOf], `for` = [bl bob])
    check m.answer(ByQ) == some bl(alice)
    check m.answer(SaidQ) == some bl("hi back")
    check m.answer(ReQ) == some first.digestOf
    check m.answer(ForQ) == some bl(bob)
    check m.answer(AtQ).isSome

  test "a message is for whom it names, by any of their names, and for all is for everyone":
    let alice = Speaker(name: bl alice)
    let bob = identity(bl bob, bl 0x0b0b)
    check alice.message(bl "hi", `for` = [bl bob]).isFor(bob)
    check alice.message(bl "hi", `for` = [bl 0x0b0b]).isFor(bob)
    check not alice.message(bl "hi", `for` = [bl carol]).isFor(bob)
    check not alice.message(bl "hi").isFor(bob)
    check alice.message(bl "hi all", `for` = [AllName]).isFor(bob)
    check alice.message(bl "hi all", `for` = [AllName]).isFor(bl carol)

  test "a signed message is vouched for when its key is a name of its speaker":
    let kp = seed(9)
    let alice = Speaker(name: bl alice, key: some kp)
    let h = heard(initRec(@[bl general, bl 0, alice.put(bl general, alice.message(bl "hi"))])).get
    check h.vouched
    check nameOf(h.said.answer(ByQ).get) == "alice"
    let mallory = Speaker(name: bl alice, key: some seed(3))
    let claimed = obj(initRec(@[ByQ, alice.by]), initRec(@[SaidQ, bl "me, honest"]))
    check not heard(initRec(@[bl general, bl 1, mallory.put(bl general, claimed)])).get.vouched

  test "who is here: those who came and haven't gone since":
    let local = spaceVar[Value, Ranked[Value]]()
    discard local.keep(initRec(@[HereQ, bl 0, readValue("!{(by alice) (at 1)}")]))
    discard local.keep(initRec(@[HereQ, bl 1, readValue("!{(by bob) (at 2)}")]))
    discard local.keep(initRec(@[GoneQ, bl 2, readValue("!{(by alice) (at 3)}")]))
    check local.who == @[bl bob]
    discard local.keep(initRec(@[HereQ, bl 3, readValue("!{(by alice) (at 4)}")]))
    check local.who == @[bl bob, bl alice]

  test "who was here when the jam heard something: they came before it and hadn't gone":
    let local = spaceVar[Value, Ranked[Value]]()
    discard local.keep(initRec(@[HereQ, bl 2, readValue("!{(by alice) (at 1)}")]))
    discard local.keep(initRec(@[GoneQ, bl 5, readValue("!{(by alice) (at 2)}")]))
    discard local.keep(initRec(@[HereQ, bl 8, readValue("!{(by !{(identity alice) (identity 0x0a)}) (at 3)}")]))
    check not local.wasHere(bl alice, 1)
    check local.wasHere(bl alice, 3)
    check not local.wasHere(bl alice, 6)
    check local.wasHere(readValue("0x0a"), 9)
    check not local.wasHere(bl bob, 3)

proc teaMsg(rank: int, d, prev: Value, at = 0): Value =
  ## a jam's stamp for `rank`: its message that it heard the answer with
  ## digest `d` in general
  TeaMsg(ordinal: rank, at: at, prev: prev, value: initRec(@[bl general, d])).toValue

proc stampTold(kp: Keypair, sq: Value, rank: int, d, prev: Value): (Value, Value) =
  ## a stamp for `rank` as a jam would tell it, signed by `kp`, and the
  ## message itself
  let record = teaMsg(rank, d, prev)
  (initRec(@[sq, toValue(rank), kp.signed(record).toValue]), record)

proc d(v: Value): Value = digest(v, Blake2bAlgo).toValue

suite "stamps":
  let kp = seed(5)
  let sq = bl(stamps(jam))

  test "a jam with a key stamps each answer it keeps, at its rank, and says where in its own here":
    let jam = newJam(spaceVar[Value, Ranked[Value]](), key = some kp)
    let (told, t) = listener()
    let line = jam.newLine(t)
    check jam.hear(line, bl(general("hi")))
    check jam.hear(line, bl(general("again")))
    for q in [sq, bl(general), HereQ]: check jam.hear(line, initRec(@[q]))
    let local = spaceVar[Value, Ranked[Value]]()
    for v in told[]: discard local.keep(v)
    let here = toSeq(local.heardIn(HereQ))
    check here.len == 1 and here[0].vouched
    check here[0].said.answer(StampsQ) == some sq
    let said = toSeq(local.heardIn(bl general))
    check said.mapIt(it.rank) == @[2, 3]
    let ss = toSeq(local.stamps(sq, kp.pubkey))
    check ss.mapIt(it.rank) == @[0, 1, 2, 3]       # jam, here, hi, again
    check ss[2].vouches(said[0]) and ss[3].vouches(said[1])
    check not ss[2].vouches(said[1])
    check ss[0].prev == bl(nil) and ss[1].prev == d(ss[0].record)
    check local.unchained(sq, kp.pubkey).len == 0

  test "a line may ask a jam's stamps, and not put to them":
    let jam = newJam(spaceVar[Value, Ranked[Value]](), key = some kp)
    let (_, t) = listener()
    let line = jam.newLine(t)
    check not jam.hear(line, initRec(@[sq, bl "a stamp of my own"]))
    check jam.hear(line, initRec(@[sq]))
    check jam.hear(line, initRec(@[bl(stamps(another)), bl "another jam's"]))

  test "a forged stamp is not read, and one another key signed isn't this key's":
    let local = spaceVar[Value, Ranked[Value]]()
    let (good, record) = stampTold(kp, sq, 0, d(bl "hi"), bl(nil))
    var forged = good
    let signed = good.items[2]
    let changed = teaMsg(0, d(bl "bye"), bl(nil))
    forged = initRec(@[sq, bl 0, initRec(@[signed.items[0], changed, signed.items[2]])])
    discard local.keep(forged)
    check toSeq(local.stamps(sq, kp.pubkey)).len == 0
    discard local.keep(stampTold(seed(6), sq, 1, d(bl "hi"), d(record))[0])
    check toSeq(local.stamps(sq, kp.pubkey)).len == 0
    check toSeq(local.stamps(sq, seed(6).pubkey)).len == 1

  test "a stamp missing, reordered or signed twice for one rank breaks the chain":
    let (t0, r0) = stampTold(kp, sq, 0, d(bl "a"), bl(nil))
    let (t1, r1) = stampTold(kp, sq, 1, d(bl "b"), d(r0))
    let (t2, _) = stampTold(kp, sq, 2, d(bl "c"), d(r1))
    let whole = spaceVar[Value, Ranked[Value]]()
    for v in [t0, t1, t2]: discard whole.keep(v)
    check whole.unchained(sq, kp.pubkey).len == 0
    let missing = spaceVar[Value, Ranked[Value]]()
    for v in [t0, t2]: discard missing.keep(v)
    check missing.unchained(sq, kp.pubkey).mapIt(it.rank) == @[2]
    let (u2, s2) = stampTold(kp, sq, 2, d(bl "c"), d(r0))
    let (u1, _) = stampTold(kp, sq, 1, d(bl "b"), d(s2))
    let reordered = spaceVar[Value, Ranked[Value]]()
    for v in [t0, u1, u2]: discard reordered.keep(v)
    check reordered.unchained(sq, kp.pubkey).mapIt(it.rank) == @[1, 2]
    let (w1, _) = stampTold(kp, sq, 1, d(bl "other"), d(r0))
    let twice = spaceVar[Value, Ranked[Value]]()
    for v in [t0, t1, w1]: discard twice.keep(v)
    check twice.unchained(sq, kp.pubkey).mapIt(it.rank) == @[1]

  test "a jam opened again on its log chains its stamps on":
    let path = getTempDir() / "tjam-stamps.blb"
    removeFile(path)
    defer: removeFile(path)
    block:
      let jam = newJam(logVar[Value, Ranked[Value]](path), key = some kp)
      let (_, t) = listener()
      check jam.hear(jam.newLine(t), bl(general("first")))
    let again = newJam(logVar[Value, Ranked[Value]](path), key = some kp)
    let (told, t) = listener()
    let line = again.newLine(t)
    check again.hear(line, bl(general("second")))
    check again.hear(line, initRec(@[sq]))
    let local = spaceVar[Value, Ranked[Value]]()
    for v in told[]: discard local.keep(v)
    let ss = toSeq(local.stamps(sq, kp.pubkey))
    check ss.mapIt(it.rank) == @[0, 1, 2, 3, 4, 5]   # jam, here, first, gone, here, second
    check local.unchained(sq, kp.pubkey).len == 0

  test "a signed put of a tea-msg is that key's put, not its stamp":
    let local = spaceVar[Value, Ranked[Value]]()
    let put = kp.signed(initRec(@[sq, teaMsg(0, d(bl "a"), bl(nil))])).toValue
    check local.keep(initRec(@[sq, bl 0, put])).isSome
    check toSeq(local.stamps(sq, kp.pubkey)).len == 0

  test "a log with a hole or a fork in a key's stamps is not that key's to go on with":
    let (t0, r0) = stampTold(kp, sq, 0, d(bl "a"), bl(nil))
    let (t2, _) = stampTold(kp, sq, 2, d(bl "c"), d(r0))
    let (w0, _) = stampTold(kp, sq, 0, d(bl "other"), bl(nil))
    let holed = spaceVar[Value, Ranked[Value]]()
    for v in [t0, t2]: discard holed.keep(v)
    expect BasslineError: discard newJam(holed, key = some kp)
    let forked = spaceVar[Value, Ranked[Value]]()
    for v in [t0, w0]: discard forked.keep(v)
    expect BasslineError: discard newJam(forked, key = some kp)
    discard newJam(holed)          # without the key it is any log

  test "a marked rank or clock is no rank: neither heard nor a stamp reads it":
    check heard(readValue("(general 3! hi)")).isNone
    check heard(readValue("(general 3 hi)")).isSome
    let marked = initRec(@[sym"tea-msg", readValue("3!"), bl 0, bl(nil), initRec(@[bl general, d(bl "a")])])
    check stampOf(marked, kp.pubkey).isNone
    let late = initRec(@[sym"tea-msg", bl 3, readValue("0!"), bl(nil), initRec(@[bl general, d(bl "a")])])
    check stampOf(late, kp.pubkey).isNone
    check stampOf(teaMsg(3, d(bl "a"), bl(nil)), kp.pubkey).isSome

suite "passing through":
  const digests = "(shape ((digest a h) v) {a h v})"

  test "what fits a shape it passes is told to whoever asks now, as (Q nil A), and kept nowhere":
    let jam = memoryJam(passes = [digests])
    let (now, a) = listener()
    let (later, b) = listener()
    let (alice, bob) = (jam.newLine(a), jam.newLine(b))
    check jam.hear(alice, rv"((digest blake2b 0x01))")
    check jam.hear(bob, rv"((digest blake2b 0x01) 0xbeef)")
    check now[] == @[rv"((digest blake2b 0x01) nil 0xbeef)"]
    check jam.hear(bob, rv"((digest blake2b 0x01))")
    check later[].len == 0                       # nobody asking later is told it
    check jam.hear(bob, rv"(general hi)")        # what fits no shape is kept
    check jam.hear(bob, rv"(general)")
    check later[] == @[rv"(general 1 hi)"]       # and takes the next rank

  test "it tells what it passes the same way, and no line puts to it":
    let jam = memoryJam(passes = [digests, "(shape (typing w) {w})"])
    let (told, t) = listener()
    let line = jam.newLine(t)
    check jam.hear(line, rv"(passes)")
    check told[].len == 2 and told[].allIt(it.items[0] == PassesQ and it.items[1] == rv"nil")
    check told[].mapIt(it.items[2]).toSet == @[rv(digests), rv"(shape (typing w) {w})"].toSet
    check not jam.hear(line, rv"(passes (shape (general w) {w}))")
    check told[].len == 2
    check memoryJam().hear(line, rv"(passes)")   # none, for a jam that keeps everything

  test "a signed answer passes as it was put, and only a signature that holds":
    let kp = seed(9)
    let jam = newJam(spaceVar[Value, Ranked[Value]](), signedOnly = true,
                     passes = [rewrite.Shape.fromValue(rv(digests))])
    let (told, t) = listener()
    let line = jam.newLine(t)
    let alice = Speaker(name: rv"alice", key: some kp)
    check jam.hear(line, alice.ask(rv"(digest blake2b 0x02)"))
    let said = alice.put(rv"(digest blake2b 0x02)", rv"0xcafe")
    check jam.hear(line, said)
    check not jam.hear(line, rv"((digest blake2b 0x02) 0xcafe)")   # unsigned
    check told[] == @[initRec(@[rv"(digest blake2b 0x02)", rv"nil", said])]
    let p = passedOf(told[0]).get
    check p.said == rv"0xcafe" and p.signer == some(kp.pubkey) and p.answer == said
    check heard(told[0]).isNone                  # it has no rank to be heard at

  test "a reader keeps no passed answer in its ranked space":
    let local = spaceVar[Value, Ranked[Value]]()
    check local.keep(rv"(q nil a)").isNone
    check local.heardIn(rv"q").toSeq.len == 0
    check passedOf(rv"(q nil a)").get.said == rv"a"
    check passedOf(rv"(q 1 a)").isNone
