import std/[os, sequtils, unittest]
import bassline, bassline_crypto, bassline_jam

let
  alice = newKeypair()
  bob = newKeypair(EddsaBlake2b)
  jamKey = newKeypair(EddsaBlake2b)

type Recorder = ref object of Conn
  told: seq[Node]
  closed: bool

method send(r: Recorder, ce: sink string) =
  if not r.closed:
    var reader = initReader()
    r.told.add reader.readOne(ce).toNode

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

proc scratch(name: string): string =
  result = getTempDir() / name
  removeFile(result)

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

suite "kept in a log":
  test "opened again it holds what it held, ranks going on, and is the same jam":
    let path = scratch("tjam-log.blb")
    defer: removeFile(path)
    let first = alice.put(bl"general", Text"first")
    block:
      check newJam(bl"jam", jamKey, path).lines.accept.says(first)
    let again = newJam(bl"jam", newKeypair(EddsaBlake2b), path)
    let line = again.lines.accept
    let second = alice.put(bl"general", Text"second")
    check line.says(first)                       # kept already
    check line.says(second)
    check line.says(alice.ask(bl"general"))
    check line.told == @[told(bl"general", 1, first), told(bl"general", 2, second)]
    let kept = readAll(readFile(path)).mapIt(it.toNode)
    check kept.len == 3 and kept[0][0] == jamQ and kept[0][1] == Num(0)
    check kept[1 .. ^1] == @[told(bl"general", 1, first), told(bl"general", 2, second)]
    let which = again.lines.accept
    check which.says(alice.ask(jamQ))
    check which.told == @[kept[0]]

  test "a jam opened on a log says whoever it held as here is gone":
    let path = scratch("tjam-presence.blb")
    defer: removeFile(path)
    block:
      check newJam(bl"jam", jamKey, path).lines.accept.says(bob.put(hereQ, bl"!{(by bob) (at 1)}"))
    let again = newJam(bl"jam", jamKey, path)
    check again.who.len == 0
    let records = readAll(readFile(path)).mapIt(it.toNode)
    check records.len == 3 and records[2].by == @[bl"bob"]
    check records[2][0] == goneQ

  test "a log cut short partway through a record is cut back to the last whole one":
    let path = scratch("tjam-torn.blb")
    defer: removeFile(path)
    block:
      discard newJam(bl"jam", jamKey, path)
    let whole = readFile(path)
    var torn: string
    told(bl"general", 1, alice.put(bl"general", Text"torn")).write(torn)
    writeFile(path, whole & torn[0 .. 5])
    let again = newJam(bl"jam", jamKey, path)
    check again.len == 1 and readFile(path) == whole

  test "a log holding what isn't signed is refused, and left as it was":
    let path = scratch("tjam-unsigned.blb")
    defer: removeFile(path)
    var bytes: string
    bl"(jam 0 !{(identity jam)})".write(bytes)
    writeFile(path, bytes)
    expect BasslineError:
      discard newJam(bl"jam", jamKey, path)
    check readFile(path) == bytes

  test "a log that doesn't begin by saying which jam it is is refused":
    let path = scratch("tjam-headless.blb")
    defer: removeFile(path)
    var bytes: string
    told(bl"general", 0, alice.put(bl"general", Text"first")).write(bytes)
    writeFile(path, bytes)
    expect BasslineError:
      discard newJam(bl"jam", jamKey, path)

  test "what the log can't take isn't kept, and spends no rank":
    let path = scratch("tjam-readonly.blb")
    defer:
      setFilePermissions(path, {fpUserRead, fpUserWrite})
      removeFile(path)
    let jam = newJam(bl"jam", jamKey, path)
    let line = jam.lines.accept
    check line.says(alice.ask(bl"general"))
    setFilePermissions(path, {fpUserRead})
    discard line.says(alice.put(bl"general", Text"lost"))
    check jam.len == 1 and line.told.len == 0
    setFilePermissions(path, {fpUserRead, fpUserWrite})
    let kept = alice.put(bl"general", Text"kept")
    check line.says(kept)
    check line.told == @[told(bl"general", 1, kept)]
    check newJam(bl"jam", jamKey, path).len == 2

  test "a jam can't begin on a log it can't write":
    expect BasslineError:
      discard newJam(bl"jam", jamKey, getTempDir() / "tjam-no-such-dir" / "tjam.blb")

suite "over tcp":
  test "a jam served on a port keeps what lines put and tells what they ask":
    let jam = memoryJam()
    let listener = newListener("127.0.0.1", Port(0))
    listener.up Lines(jam: jam)
    asyncCheck listener.serve
    let port = listener.port
    let seen = Track()
    let watcher = waitFor connect("127.0.0.1", port)
    watcher.into = seen
    asyncCheck watcher.read
    watcher.write alice.ask(bl"general")
    watcher.write alice.ask(goneQ)
    let speaker = waitFor connect("127.0.0.1", port)
    speaker.write bob.put(hereQ, bl"!{(by bob) (at 1)}")
    let hi = bob.put(bl"general", Text"hi over tcp")
    speaker.write hi
    waitFor speaker.flush
    speaker.close
    for _ in 0 ..< 100:
      if seen.len >= 2: break
      poll(10)
    let heardOver = seen.nodes
    check heardOver.len == 2
    check heardOver[0] == told(bl"general", 2, hi)
    check heardOver[1][0] == goneQ and heardOver[1].by == @[bl"bob"]
    watcher.close
    listener.close
