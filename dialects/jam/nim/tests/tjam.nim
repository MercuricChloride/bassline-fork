import std/[sequtils, unittest]
import bassline, bassline_crypto, bassline_jam

let
  alice = newKeypair()
  bob = newKeypair(EddsaBlake2b)
  jamKey = newKeypair(EddsaBlake2b)

type Recorder = ref object of Conn
  told: seq[Node]
  closed: bool

method write(r: Recorder, n: Node) =
  if not r.closed:
    r.told.add n

method close(r: Recorder) =
  r.closed = true

method isClosed(r: Recorder): bool =
  r.closed

proc lines(jam: Jam): Track =
  result = Track()
  result.up Lines(jam: jam)

proc memoryJam(): Jam =
  newJam(bl"jam", jamKey)

proc accept(conns: Track): Recorder =
  result = Recorder()
  conns.add result.toNode

proc says(r: Recorder, n: Node): bool =
  r.into.add(n) == Contribution.Kept

proc quiet(conns: Track, r: Recorder) =
  conns.reviseIt:
    for i in 0 ..< it.len:
      if it[i] == Present(n: r.toNode):
        it.delete(i)

proc told(q: Node, rank: int, a: Node): Node =
  let r = Num(rank)
  bl"($q $r $a)"

proc saidIn(told: Node): Node =
  matchValue told:
  of "($_ $_ (signed ($_ $said) $_))": said
  else: Null()

proc keyOf(told: Node): PublicKey =
  matchValue told:
  of "($_ $_ (signed $_ $sig))": sig.toSignature.publicKey
  else: PublicKey()

proc by(told: Node): seq[Node] =
  toSeq(told.saidIn.answers(byQ))

proc nodes(t: Track): seq[Node] =
  for i in 0 ..< t.len:
    case t[i]
    of Present(n): result.add n
    of Absent: discard

suite "a jam":
  test "what is put is told to whoever asks, what it has and then as it comes":
    let jam = memoryJam()
    let conns = jam.lines
    let (a, b) = (conns.accept, conns.accept)
    let hi = alice.put(bl"general", Text"hi")
    check a.says(hi)
    check b.says(bob.ask(bl"general"))
    check b.told == @[told(bl"general", 1, hi)]       # 0 is the jam's own (jam)
    let anyone = alice.put(bl"general", Text"anyone?")
    check a.says(anyone)
    check a.says(alice.put(bl"random", Text"elsewhere"))
    check b.told == @[told(bl"general", 1, hi), told(bl"general", 2, anyone)]
    check a.told.len == 0

  test "an answer put twice is kept once, and asking twice tells once":
    let jam = memoryJam()
    let line = jam.lines.accept
    let qa = alice.put(bl"q", bl"a")
    check line.says(qa)
    check line.says(qa)
    check line.says(alice.ask(bl"q"))
    check line.says(bob.ask(bl"q"))
    check line.told == @[told(bl"q", 1, qa)]
    check jam.len == 2

  test "the same answer from another key is another answer":
    let jam = memoryJam()
    let line = jam.lines.accept
    check line.says(alice.put(bl"q", bl"a"))
    check line.says(bob.put(bl"q", bl"a"))
    check line.says(alice.ask(bl"q"))
    check line.told.len == 2 and line.told.allIt(it.saidIn == bl"a")

  test "it reads neither questions nor answers, and a line keeps nothing else":
    let jam = memoryJam()
    let line = jam.lines.accept
    let odd = alice.put(bl"{alice bob}", bl"[1 2 {x: y}]")
    check line.says(odd)
    check line.says(alice.ask(bl"{alice bob}"))
    check line.told == @[told(bl"{alice bob}", 1, odd)]
    check not line.says(alice.signed(bl"(a b c)").toNode)    # three, not two
    check not line.says(alice.signed(bl"!(q a)").toNode)     # marked
    check not line.says(alice.signed(bl"hello").toNode)      # not a record

  test "what isn't signed, or whose signature doesn't hold, isn't kept":
    let jam = memoryJam()
    let line = jam.lines.accept
    check not line.says(bl"""(general "unsigned")""")
    check not line.says(bl"(general)")
    var forged = alice.put(bl"general", Text"signed hi")
    forged.asValue[1] = bl"""(general "changed")"""
    check not line.says(forged)
    check line.says(alice.ask(bl"general"))
    check line.told.len == 0 and jam.len == 1

  test "whoever is told an answer can check who said it":
    let jam = memoryJam()
    let line = jam.lines.accept
    check line.says(alice.put(bl"general", Text"signed hi"))
    check line.says(bob.ask(bl"general"))
    let t = line.told[0]
    check t[0] == bl"general" and t[1] == Num(1) and t.saidIn == Text"signed hi"
    check t[2].holds and t.keyOf == alice.publicKey

  test "it says which jam it is, signed: its name, an id of its own and when it began":
    let jam = memoryJam()
    let line = jam.lines.accept
    check line.says(alice.ask(jamQ))
    let t = line.told[0]
    check line.told.len == 1 and t[0] == jamQ and t[1] == Num(0) and t.keyOf == jamKey.publicKey
    let me = t.saidIn
    check me.knownAs(bl"jam")
    check toSeq(me.identities).filterIt(it.isKind(bBytes) and it.asValue.vstr.len == 16).len == 1
    check toSeq(me.answers(atQ)).len == 1
    check not line.says(alice.put(jamQ, Text"another jam"))   # its own to say
    check line.told.len == 1
    let other = newJam(bl"bootstrap", jamKey).lines.accept
    check other.says(alice.ask(jamQ))
    check other.told[0].saidIn != me and other.told[0].saidIn.knownAs(bl"bootstrap")

  test "a connection that stops speaking has left: who it said was here is gone, once":
    let jam = memoryJam()
    let conns = jam.lines
    let (watcher, bobs) = (conns.accept, conns.accept)
    check watcher.says(alice.ask(goneQ))
    check bobs.says(bob.put(hereQ, bl"!{(by bob) (at 1)}"))
    conns.quiet(bobs)
    check watcher.told.len == 1 and watcher.told[0].by == @[bl"bob"]
    check watcher.told[0].keyOf == jamKey.publicKey
    conns.quiet(bobs)
    check watcher.told.len == 1

  test "one gone quiet is told on while it asks, and closed when it asks nothing":
    let jam = memoryJam()
    let conns = jam.lines
    let (asking, quietOne, speaker) = (conns.accept, conns.accept, conns.accept)
    check asking.says(alice.ask(bl"q"))
    conns.quiet(asking)
    conns.quiet(quietOne)
    check not asking.closed and quietOne.closed
    let a = alice.put(bl"q", bl"a")
    check speaker.says(a)
    check asking.told == @[told(bl"q", 1, a)]
    asking.closed = true                         # it can't be told any more
    check speaker.says(alice.put(bl"q", bl"b"))
    check asking.told.len == 1

  test "who is here: those who came and haven't gone since, by any name they share":
    let jam = memoryJam()
    let line = jam.lines.accept
    let carol = bl"!{(identity carol) (identity 0x0102)}"
    check line.says(bob.put(hereQ, bl"!{(by bob) (at 1)}"))
    check line.says(alice.put(hereQ, bl"!{(by $carol) (at 2)}"))
    check jam.who == @[bl"bob", carol]
    check line.says(alice.put(goneQ, bl"!{(by 0x0102) (at 3)}"))
    check jam.who == @[bl"bob"]

  test "a jam is a signed track, so a checker reads what it keeps":
    let jam = memoryJam()
    let line = jam.lines.accept
    check line.says(alice.put(bl"q", bl"a"))
    let kept = Track()
    jam.up Checker(into: kept)
    check kept.len == 2
    check jam.add(bl"(q a)") == Contribution.Ignored
    check not line.says(alice.put(bl"q", bl"b").checked.toNode)   # live, not said
    check jam.len == 2

  test "connections held already are taken up when it joins":
    let jam = memoryJam()
    let conns = Track()
    let early = conns.accept
    conns.up Lines(jam: jam)
    check early.says(alice.ask(jamQ))
    check early.told.len == 1

  test "a revision of the jam is followed by what it tells whoever asks next":
    let jam = memoryJam()
    let line = jam.lines.accept
    check line.says(alice.put(bl"q", bl"a"))
    jam.reviseIt:
      it.delete(1)
    check line.says(alice.ask(bl"q"))
    check line.told.len == 0

suite "kept and begun again":
  test "a jam reifies to what it keeps, and begun again on that is the same jam":
    let jam = memoryJam()
    let line = jam.lines.accept
    let hi = alice.put(bl"general", Text"hi")
    check line.says(bob.put(hereQ, bl"!{(by bob) (at 1)}"))
    check line.says(hi)
    var kept = jam.reified.toNode
    check kept[1].asValue.len == 3
    kept.bindJam(newKeypair(EddsaBlake2b))
    check kept.isBound and kept.asLive of Jam
    let again = Jam(kept.asLive)
    check again.len == 4 and again[1] == jam[1] and again[2] == Present(n: hi)
    check again[0] == jam[0]                                      # the same jam
    check again.who.len == 0                                      # bob is gone
    let watcher = again.lines.accept
    check watcher.says(alice.ask(bl"general"))
    check watcher.told == @[told(bl"general", 2, hi)]

  test "what isn't a jam as it reifies isn't begun again":
    let first = memoryJam()[0]
    case first
    of Present(n):
      let (jamPut, hi) = (n, alice.put(bl"general", Text"hi"))
      var unmarked = bl"(jam [$jamPut])"
      expect BasslineError:
        unmarked.bindJam(jamKey)
      var headless = bl"!(jam [$hi $jamPut])"
      expect BasslineError:
        headless.bindJam(jamKey)                                  # not begun by its (jam)
      var unsigned = bl"""!(jam [$jamPut (general "unsigned")])"""
      expect BasslineError:
        unsigned.bindJam(jamKey)
      var kept = bl"!(jam [$jamPut $hi])"
      kept.bindJam(jamKey)
      check Jam(kept.asLive).len == 2
    of Absent:
      fail()

  test "a jam with a vacated slot doesn't reify":
    let jam = memoryJam()
    check jam.lines.accept.says(alice.put(bl"q", bl"a"))
    jam.reviseIt:
      it.delete(1)
    expect BasslineError:
      discard jam.reified

suite "a client":
  test "it keeps what a jam told, each rank once, refusing what doesn't hold":
    let client = Client(conflicts: Track())
    let a = alice.put(bl"general", Text"hi")
    check client.add(told(bl"general", 3, a)) == Contribution.Kept
    check client.add(told(bl"general", 3, a)) == Contribution.Ignored   # told again
    check client.add(told(bl"random", 4, a)) == Contribution.Ignored    # put to another question
    check client.add(told(bl"general", -1, a)) == Contribution.Ignored
    var forged = alice.put(bl"general", Text"signed hi")
    forged.asValue[1] = bl"""(general "changed")"""
    check client.add(told(bl"general", 5, forged)) == Contribution.Ignored
    check client.len == 1 and client.conflicts.len == 0

  test "another answer told at a rank it holds is a conflict, kept apart":
    let client = Client(conflicts: Track())
    let (first, other) = (told(bl"q", 1, alice.put(bl"q", bl"a")), told(bl"q", 1, bob.put(bl"q", bl"b")))
    check client.add(first) == Contribution.Kept
    check client.add(other) == Contribution.Ignored
    check client.len == 1 and client.conflicts.nodes == @[bl"(conflict $first $other)"]

  test "who is here reads what a client was told as it reads a jam":
    let client = Client()
    check client.add(told(hereQ, 1, bob.put(hereQ, bl"!{(by bob) (at 1)}"))) == Contribution.Kept
    check client.add(told(hereQ, 2, alice.put(hereQ, bl"!{(by alice) (at 2)}"))) == Contribution.Kept
    check client.add(told(goneQ, 3, alice.put(goneQ, bl"!{(by alice) (at 3)}"))) == Contribution.Kept
    check client.who == @[bl"bob"]

suite "over tcp":
  test "a jam served on a port keeps what lines put, and a client keeps what it tells once":
    let jam = memoryJam()
    let listener = newListener("127.0.0.1", Port(0))
    listener.up Lines(jam: jam)
    asyncCheck listener.serve
    let port = listener.port
    let client = Client(conflicts: Track())
    var watchers: seq[TcpConn]
    for _ in 0 ..< 2:                            # dialled again, it is told all again
      let watcher = waitFor connect("127.0.0.1", port)
      watcher.into = client
      asyncCheck watcher.read
      watcher.write alice.ask(bl"general")
      watcher.write alice.ask(goneQ)
      watchers.add watcher
      if watchers.len == 1:
        let speaker = waitFor connect("127.0.0.1", port)
        speaker.write bob.put(hereQ, bl"!{(by bob) (at 1)}")
        speaker.write bob.put(bl"general", Text"hi over tcp")
        waitFor speaker.flush
        speaker.close
      for _ in 0 ..< 50:
        poll(10)
    let held = client.nodes
    check held.len == 2 and client.conflicts.len == 0
    check held[0] == told(bl"general", 2, bob.put(bl"general", Text"hi over tcp"))
    check held[1][0] == goneQ and held[1].by == @[bl"bob"]
    for watcher in watchers:
      watcher.close
    listener.close
