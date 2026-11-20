import std/[os, unittest]
import bassline

type Small = ref object of Track

method keeps(self: Small, n: Node): bool =
  n.isKind(bNum)

proc nodes(t: Track): seq[Node] =
  for i in 0 ..< t.len:
    case t[i]
    of Present(n): result.add n
    of Absent: discard

suite "monitors":
  test "a relay offers what is held when it joins, then each addition, and no revision":
    let (source, into) = (Track(), Track())
    source.add bl"a"
    source.up Relay(into: into)
    source.add bl"b"
    source.reviseIt:
      it[0] = bl"changed"
    check into.nodes == @[bl"a", bl"b"]

  test "relaying into a track that keeps less filters what is relayed":
    let (source, into) = (Track(), Small())
    source.up Relay(into: into)
    for n in [bl"1", bl"one", bl"2"]:
      source.add n
    check into.nodes == @[bl"1", bl"2"]

  test "a printer writes each change after it joins as a value, one a line":
    let path = getTempDir() / "tmonitors-printed.bl"
    defer: removeFile(path)
    let to = open(path, fmWrite)
    let t = Track()
    t.add bl"held"
    t.up Printer(to: to)
    t.add bl"(said hi)"
    t.reviseIt:
      it.delete(0)
      it[1] = bl"(said bye)"
    to.close
    let printed = Value.parseMany(readFile(path))
    check printed.len == 3
    check printed[0].toNode == bl"(added 1 (said hi))"
    check printed[1].toNode == bl"(revised 0 (present held) Absent)"
    check printed[2].toNode == bl"(revised 1 (present (said hi)) (present (said bye)))"
