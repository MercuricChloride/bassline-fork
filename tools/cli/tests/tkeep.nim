## bl jam keep: wants answered from a keep, once among keepers, and keeps
## fetched whole

import std/sugar
import cli
import bl/queries
import bl/lib/fs
from bl/lib/jam import Heard, byQ, reQ, nameOf

proc keeper(s: Serving, keep, name: string, extra: seq[string] = @[]): Process =
  ## `bl jam keep` as `name` on the jam `s`, keeping in `keep`
  startProcess(bin / "bl-jam", args = @["keep", "--at", ":" & s.port, "--as", name,
                                       "--keep", keep] & extra, options = {})

proc stopKeeper(p: Process) =
  discard kill(Pid(p.processID), SIGTERM)
  discard p.waitForExit
  p.close()

proc messages(vs: seq[Value], room: Value): seq[Heard] =
  ## what was said in `room`, out of its signature
  for v in vs:
    let h = heard(v)
    if h.isSome and h.get.q == room: result.add h.get

proc saying(vs: seq[Value], room: Value, by: string, q: Value): seq[Heard] =
  ## what `by` said in `room` that answers `q`
  vs.messages(room).filterIt(it.said.answer(byQ).isSome and
    nameOf(it.said.answer(byQ).get) == by and it.said.answer(q).isSome)

proc answersTo(vs: seq[Value], d: Value): seq[Value] =
  ## what the jam told as answers to `d`, out of its signature
  for v in vs:
    let h = heard(v)
    if h.isSome and h.get.q == d: result.add h.get.said

proc digestsOf(h: Heard, q: Value): seq[Value] = h.said.answers(q).toSeq

proc bytesFor(n: int, seed: int): seq[byte] =
  ## n bytes that cut into several chunks, the same for the same seed
  var x = uint32(seed * 2654435761 + 1)
  for _ in 0 ..< n:
    x = x * 1664525 + 1013904223
    result.add byte(x shr 24)

let fsRoom = sym"fs"

proc ready(line: Socket, heard: var seq[Value], names: varargs[string]) =
  ## heard until each keeper has said it keeps here
  let names = @names
  proc spoke(vs: seq[Value], name: string): bool =
    vs.messages(fsRoom).anyIt(it.said.answer(byQ).isSome and
                              nameOf(it.said.answer(byQ).get) == name)
  line.hearUntil(heard, (vs: seq[Value]) => names.allIt(vs.spoke(it)))

suite "keep":
  test "a want is answered with what the keeper holds, once its has is told back":
    let keepA = tmp / "a.blb"
    let k = openKeep(keepA)
    let small = k.addBytes(@[byte 1, 2, 3])
    let big = k.addBytes(bytesFor(200_000, 1))
    let nobody = digestOf(text("held by no one"))
    k.close()
    let jam = jamServe()
    let ka = jam.keeper(keepA, "ka")
    let line = jam.asking(blb("(fs) (" & $small & ") (" & $big & ") (" & $nobody & ")"))
    var heard: seq[Value]
    line.ready(heard, "ka")
    check jam.put(blb("(fs !{(by bob) (at 1) (want " & $small & ") (want " & $big &
                      ") (want " & $nobody & ")})")).code == 0
    line.hearUntil(heard, (vs: seq[Value]) =>
      vs.answersTo(small).len > 0 and vs.answersTo(big).len > 0)
    let has = heard.saying(fsRoom, "ka", sym"has")
    check has.len == 1
    check has[0].digestsOf(sym"has").sorted == @[small, big].sorted
    check heard.answersTo(small) == @[bytes(@[byte 1, 2, 3])]
    check verifies(big, heard.answersTo(big)[0])
    check heard.answersTo(nobody).len == 0
    line.close()
    ka.stopKeeper()
    discard jam.stop

  test "of keepers holding one digest the first to say has puts it, so the jam keeps it once":
    let d = block:
      var d: Value
      for name in ["b1.blb", "b2.blb"]:
        let k = openKeep(tmp / name)
        d = k.addBytes(bytesFor(1000, 2))
        k.close()
      d
    for name in ["b1", "b2"]:
      check sh("bl clave keygen --out " & tmp / (name & ".key")).code == 0
    let jam = jamServe(@["--memory", "--clave"])
    let k1 = jam.keeper(tmp / "b1.blb", "b1", @["--key", tmp / "b1.key"])
    let k2 = jam.keeper(tmp / "b2.blb", "b2", @["--key", tmp / "b2.key"])
    check sh("bl clave keygen --out " & tmp / "bob.key").code == 0
    let line = jam.asking(sh("bl clave sign --key " & tmp / "bob.key",
                             blb("(fs) (" & $d & ")")).output)
    var heard: seq[Value]
    line.ready(heard, "b1", "b2")
    check sh("bl clave sign --key " & tmp / "bob.key | bl reach --source :" & jam.port,
             blb("(fs !{(by bob) (at 1) (want " & $d & ")})")).code == 0
    line.hearUntil(heard, (vs: seq[Value]) =>
      vs.saying(fsRoom, "b1", sym"has").len + vs.saying(fsRoom, "b2", sym"has").len == 2 and
        vs.answersTo(d).len > 0)
    line.hearUntil(heard, (vs: seq[Value]) => false, rounds = 3)
    check heard.answersTo(d).len == 1
    check verifies(d, heard.answersTo(d)[0])
    line.close()
    k1.stopKeeper()
    k2.stopKeeper()
    discard jam.stop

  test "a keep is fetched whole from what another keeper puts, and said kept":
    let dir = tmp / "tree"
    createDir(dir / "sub")
    writeFile(dir / "small.txt", "hello\n")
    writeFile(dir / "sub" / "big.bin", cast[string](bytesFor(150_000, 3)))
    let keepA = tmp / "ta.blb"
    let keepB = tmp / "tb.blb"
    let ka = openKeep(keepA)
    let tree = named(ka.add(dir)).get
    let all = ka.held
    ka.close()
    let jam = jamServe()
    let pa = jam.keeper(keepA, "ka")
    let pb = jam.keeper(keepB, "kb")
    let line = jam.asking(blb("(fs)"))
    var heard: seq[Value]
    line.ready(heard, "ka", "kb")
    check jam.put(blb("(fs !{(by bob) (at 1) (for kb) (keep " & $tree & ")})")).code == 0
    line.hearUntil(heard, (vs: seq[Value]) => vs.saying(fsRoom, "kb", sym"kept").len > 0,
                   rounds = 50)
    let kept = heard.saying(fsRoom, "kb", sym"kept")
    check kept.len == 1 and kept[0].digestsOf(sym"kept") == @[tree]
    check heard.saying(fsRoom, "kb", sym"want").len > 0
    check heard.saying(fsRoom, "ka", sym"kept").len == 0
    let kb = openKeep(keepB)
    check keepSearch(kb).missing(tree).len == 0
    check all.allIt(kb.holds(it))
    kb.close()
    line.close()
    pa.stopKeeper()
    pb.stopKeeper()
    discard jam.stop

  test "a want said while the keeper was away is taken up when it comes, and only once":
    let keepA = tmp / "c.blb"
    let k = openKeep(keepA)
    let d1 = k.addBytes(@[byte 7])
    let d2 = k.addBytes(@[byte 8])
    k.close()
    let jam = jamServe()
    let line = jam.asking(blb("(fs) (" & $d1 & ") (" & $d2 & ")"))
    check jam.put(blb("(fs !{(by bob) (at 1) (want " & $d1 & ")})")).code == 0
    var ka = jam.keeper(keepA, "ka")
    var heard: seq[Value]
    line.hearUntil(heard, (vs: seq[Value]) => vs.answersTo(d1).len > 0)
    ka.stopKeeper()
    ka = jam.keeper(keepA, "ka")
    check jam.put(blb("(fs !{(by bob) (at 2) (want " & $d2 & ")})")).code == 0
    line.hearUntil(heard, (vs: seq[Value]) => vs.answersTo(d2).len > 0)
    let has = heard.saying(fsRoom, "ka", sym"has")
    check has.len == 2
    check has.mapIt(it.digestsOf(sym"has")) == @[@[d1], @[d2]]
    line.close()
    ka.stopKeeper()
    discard jam.stop

  test "a want said with the keeper's own key is answered like any other":
    let keepA = tmp / "own.blb"
    let k = openKeep(keepA)
    let d = k.addBytes(@[byte 9, 9])
    k.close()
    let key = tmp / "alice.key"
    check sh("bl clave keygen --out " & key).code == 0
    let jam = jamServe(@["--memory", "--clave"])
    let ka = jam.keeper(keepA, "alice", @["--key", key])
    let line = jam.asking(sh("bl clave sign --key " & key, blb("(fs) (" & $d & ")")).output)
    var heard: seq[Value]
    line.ready(heard, "alice")
    check sh("bl clave sign --key " & key & " | bl reach --source :" & jam.port,
             blb("(fs !{(by alice) (at 1) (want " & $d & ")})")).code == 0
    line.hearUntil(heard, (vs: seq[Value]) => vs.answersTo(d).len > 0)
    check heard.answersTo(d) == @[bytes(@[byte 9, 9])]
    line.close()
    ka.stopKeeper()
    discard jam.stop

suite "keep, on a jam passing content through":
  const digests = "(shape ((digest a h) v) {a h v})"

  test "bl jam serve --pass tells what fits to whoever asks then, keeps it nowhere, and says what it passes":
    let log = tmp / "passing.blb"
    let jam = jamServe(@["--log", log, "--pass", digests])
    let d = digestOf(bytes(@[byte 5, 5, 5]))
    let now = jam.asking(blb("(" & $d & ") (passes)"))
    check jam.put(blb("(" & $d & " 0x050505) (general hi)")).code == 0
    var heard: seq[Value]
    now.hearUntil(heard, (vs: seq[Value]) => vs.anyIt(it.items[0] == d))
    check heard.filterIt(it.items[0] == d) == decoded(blb("(" & $d & " nil 0x050505)"))
    check heard.filterIt(it.items[0] == sym"passes") ==
      decoded(blb("(passes nil " & digests & ")"))
    let later = jam.asking(blb("(" & $d & ") (general)"))
    check later.told.mapIt(it.items[0]) == @[sym"general"]
    check "0x050505" notin sh("bl cat " & log).output
    now.close()
    later.close()
    discard jam.stop
    check sh("bl-jam serve --memory --pass nonsense :0").code == 2

  test "keepers keep a tree whole off a jam that only passes it, and answer a want for it again":
    let dir = tmp / "ptree"
    createDir(dir / "sub")
    writeFile(dir / "a.txt", "passing\n")
    writeFile(dir / "sub" / "b.bin", cast[string](bytesFor(140_000, 4)))
    let ka = openKeep(tmp / "pa.blb")
    let tree = named(ka.add(dir)).get
    let all = ka.held
    ka.close()
    let jam = jamServe(@["--memory", "--pass", digests])
    let pa = jam.keeper(tmp / "pa.blb", "ka")
    let pb = jam.keeper(tmp / "pb.blb", "kb")
    let line = jam.asking(blb("(fs) (" & $tree & ")"))
    var heard: seq[Value]
    line.ready(heard, "ka", "kb")
    check jam.put(blb("(fs !{(by bob) (at 1) (for kb) (keep " & $tree & ")})")).code == 0
    line.hearUntil(heard, (vs: seq[Value]) => vs.saying(fsRoom, "kb", sym"kept").len > 0,
                   rounds = 50)
    check heard.saying(fsRoom, "kb", sym"kept").len == 1
    let kb = openKeep(tmp / "pb.blb")
    check all.allIt(kb.holds(it))
    kb.close()
    # nothing was kept, so a want for the tree is answered again, by one of them
    let passedBefore = heard.countIt(it.items[0] == tree)
    check jam.put(blb("(fs !{(by carol) (at 2) (want " & $tree & ")})")).code == 0
    line.hearUntil(heard, (vs: seq[Value]) => vs.countIt(it.items[0] == tree) > passedBefore)
    check heard.filterIt(it.items[0] == tree).allIt(it.items[1] == rv"nil")
    line.close()
    pa.stopKeeper()
    pb.stopKeeper()
    discard jam.stop
