## Files across two jams: a keeper on each and a bridge between them, a
## tree asked for on one jam fetched whole from a keeper on the other

import std/sugar
import cli
import bl/lib/fs
from bl/lib/jam import Heard, byQ, nameOf

proc keeper(s: Serving, keep, name: string): Process =
  ## `bl jam keep` as `name` on the jam `s`, keeping in `keep`
  startProcess(bin / "bl-jam", args = @["keep", "--at", ":" & s.port, "--as", name,
                                       "--keep", keep], options = {})

proc stopKeeper(p: Process) =
  discard kill(Pid(p.processID), SIGTERM)
  discard p.waitForExit
  p.close()

proc bridge(a, b: Serving): Process =
  ## `bl jam bridge` between `a` and `b`, once it says it is bridging
  result = startProcess(bin / "bl-jam", args = @["bridge", ":" & a.port, ":" & b.port],
                        options = {})
  let said = result.errorStream.readLine
  doAssert said.startsWith("-- bridging "), said

proc stopBridge(p: Process) =
  discard kill(Pid(p.processID), SIGTERM)
  discard p.waitForExit
  p.close()

let fsRoom = sym"fs"

proc saying(vs: seq[Value], by: string, q: Value): seq[Heard] =
  ## what `by` said in fs that answers `q`
  for v in vs:
    let h = heard(v)
    if h.isSome and h.get.q == fsRoom:
      let who = h.get.said.answer(byQ)
      if who.isSome and nameOf(who.get) == by and h.get.said.answer(q).isSome:
        result.add h.get

proc spoke(vs: seq[Value], by: string): bool =
  vs.saying(by, byQ).len > 0

proc bytesFor(n: int, seed: int): seq[byte] =
  ## n bytes that cut into several chunks, the same for the same seed
  var x = uint32(seed * 2654435761 + 1)
  for _ in 0 ..< n:
    x = x * 1664525 + 1013904223
    result.add byte(x shr 24)

proc sameTree(a, b: string): bool =
  ## whether the files, directories and links under `a` and `b` are the same
  for path in walkDirRec(a, yieldFilter = {pcFile, pcLinkToFile, pcLinkToDir, pcDir},
                         relative = true):
    let (pa, pb) = (a / path, b / path)
    if symlinkExists(pa):
      if not symlinkExists(pb) or expandSymlink(pa) != expandSymlink(pb): return false
    elif dirExists(pa):
      if not dirExists(pb): return false
    elif not fileExists(pb) or readFile(pa) != readFile(pb): return false
  true

template across(serving: seq[string]) =
  ## a tree added to a keep on jam A, asked for on jam B by a keeper there,
  ## through a bridge, and written out from B's keep the same as it was
  let dir = tmp / "tree"
  removeDir(tmp / "out")
  if not dirExists(dir):
    createDir(dir / "sub")
    writeFile(dir / "small.txt", "hello\n")
    writeFile(dir / "sub" / "big.bin", cast[string](bytesFor(150_000, 3)))
    createSymlink("sub/big.bin", dir / "latest")
  let (keepA, keepB) = (tmp / "a.blb", tmp / "b.blb")
  removeFile(keepB)
  let ka = openKeep(keepA)
  let root = ka.add(dir)
  let tree = named(root).get
  let all = ka.held
  ka.close()

  let (a, b) = (jamServe(serving), jamServe(serving))
  check a.put(blb("(rooms fs)")).code == 0
  let br = bridge(a, b)
  let pa = a.keeper(keepA, "ka")
  let pb = b.keeper(keepB, "kb")
  let line = b.asking(blb("(fs)"))
  var heard: seq[Value]
  line.hearUntil(heard, vs => vs.spoke("ka") and vs.spoke("kb"))
  check heard.spoke("ka")    # ka is on the other jam: what it says crosses

  check b.put(blb("(fs !{(by bob) (at 1) (for kb) (keep " & $tree & ")})")).code == 0
  line.hearUntil(heard, vs => vs.saying("kb", sym"kept").len > 0, rounds = 75)
  check heard.saying("kb", sym"want").len > 0
  check heard.saying("ka", sym"has").len > 0
  check heard.saying("kb", sym"kept").len == 1

  let kb = openKeep(keepB)
  check kb.keepSearch.missing(tree).len == 0
  check all.allIt(kb.holds(it))
  if kb.keepSearch.missing(tree).len == 0:
    kb.keepSearch.writeOut(root, tmp / "out")
    check sameTree(dir, tmp / "out") and sameTree(tmp / "out", dir)
  kb.close()

  line.close()
  pa.stopKeeper()
  pb.stopKeeper()
  br.stopBridge()
  discard a.stop
  discard b.stop

suite "files across a bridge":
  test "a tree kept on one jam is fetched whole by a keeper on another, and written out the same":
    across(@["--memory"])

  test "the same between jams that stamp what they keep":
    check sh("bl clave keygen --out " & tmp / "jamkey.blb").code == 0
    across(@["--memory", "--key", tmp / "jamkey.blb"])
