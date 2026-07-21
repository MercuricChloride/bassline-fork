import std/[unittest, sequtils]
import blnim/ops
import blnim/codec/[decode, encode]
import blnim/misc/[print, common]

suite "recognition":
  test "hasHead: any value as head, compared by CE equality":
    check record(sym"digest", sym"sha256").hasHead(sym"digest")
    check record(sym"digest").hasHead(sym"digest")
    check mark(record(sym"q")).hasHead(sym"q")     # v's own mark not consulted
    check record(text"digest").hasHead(text"digest")
    check not record(sym"other").hasHead(sym"digest")
    check not list(sym"digest").hasHead(sym"digest")
    check not record(sym"q").hasHead(mark(sym"q")) # the head's mark is CE

suite "accessing":
  let point = record(sym"point", num"3", num"4")
  let d = dict(@[(sym"a", num"1"), (sym"b", num"2")])

  test "[] for positional kinds":
    check point[0] == some sym"point"
    check point[1] == some num"3"
    check point[2] == some num"4"
    check point[3].isNone
    expect(AssertionDefect):
      discard point[-1]
    
    check list(num"9")[0] == some num"9"
    check num"5"[0].isNone
    check set(num"1", num"2")[0].isNone

  test "[] by key: dicts are keyed, not positional":
    check d[sym"b"] == some num"2"
    check d[sym"z"].isNone
    check d[0].isNone
    check num"5"[sym"k"].isNone

  test "[] by value: sets answer with their own element":
    let s = set(num"10", num"2", num"9")
    check s[num"2"] == some num"2"
    check s[num"9"] == some num"9"
    check s[num"10"] == some num"10"
    check s[num"3"].isNone

suite "search is the spelling":
  let point = record(sym"point", num"3", num"4")
  let d = dict(@[(sym"a", num"1"), (sym"b", num"2")])

  test "children: heads and keys included, document order":
    check toSeq(point.children) == @[sym"point", num"3", num"4"]
    check toSeq(d.children) == @[sym"a", num"1", sym"b", num"2"]
    check toSeq(text"x".children).len == 0

  test "contains: anything among the children counts":
    let s = set(num"10", num"2", num"9")
    check num"2" in s and num"9" in s and num"10" in s
    check num"3" notin s
    check sym"point" in point       # the head is a child
    check num"3" in point
    check num"5" notin point
    check sym"a" in d               # keys are children
    check num"1" in d               # values are children
    check sym"z" notin d
    check sym"x" notin num"5"       # scalars contain nothing

suite "shallow rewriting is the content lens":
  let point = record(sym"point", num"3", num"4")
  let d = dict(@[(sym"a", num"1"), (sym"b", num"2")])

  test "map: record head stays":
    let wrapped = point.map(proc (x: Value): Value = list(x))
    check wrapped == record(sym"point", list(num"3"), list(num"4"))
    check wrapped.head == sym"point"

  test "map: dict keys stay, values move":
    let wrapped = d.map(proc (x: Value): Value = list(x))
    check wrapped == dict(@[(sym"a", list(num"1")), (sym"b", list(num"2"))])

  test "map: sets remint, collisions dedupe":
    let collapsed = set(num"1", num"2", num"3").map(
      proc (x: Value): Value = sym"one")
    check collapsed == set(sym"one")

  test "map: scalars untouched, f unapplied; marks survive":
    var calls = 0
    check num"5".map(proc (x: Value): Value = (inc calls; x)) == num"5"
    check calls == 0
    check mark(list(num"1")).map(proc (x: Value): Value = x).marked

  test "filter: the head survives a reject-all pred":
    check point.filter(proc (x: Value): bool = false) == record(sym"point")

  test "filter: dict entries kept by their value":
    check d.filter(proc (x: Value): bool = x == num"2") ==
      dict(@[(sym"b", num"2")])
    check list(num"1", num"2").filter(proc (x: Value): bool = x == num"1") ==
      list(num"1")

suite "deep rewriting is the spelling":
  let d = dict(@[(sym"a", num"1"), (sym"bb", num"2")])

  test "transform: bottom-up, document order, heads visited":
    var order: seq[string]
    discard record(sym"h", list(sym"a")).transform(
      proc (x: Value): Value = (order.add $x; x))
    check order == @["h", "a", "[a]", "(h [a])"]

  test "transform: dict keys rewritten, entries resorted":
    let rekeyed = d.transform(
      proc (x: Value): Value = (if x == sym"a": sym"zz" else: x))
    check rekeyed == dict(@[(sym"zz", num"1"), (sym"bb", num"2")])

  test "transform: colliding keys raise like the dict constructor":
    expect ValueError:
      discard d.transform(
        proc (x: Value): Value = (if x.kind == bSym: sym"k" else: x))

  test "transform: set collisions dedupe silently":
    check set(num"1", num"2").transform(
      proc (x: Value): Value = (if x.kind == bNum: sym"n" else: x)) ==
      set(sym"n")

  test "transform: fences hold, the fence itself is still offered":
    let fenced = list(mark(list(sym"x")), sym"y")
    let unfenced = fenced.transform(proc (x: Value): Value =
      if x == sym"x": sym"CHANGED"
      elif x.marked: unmark(x)
      else: x
    , descendMarked = false)
    check unfenced == list(list(sym"x"), sym"y")

suite "deep reading":
  test "all children walks every constituent once, keys and heads counted":
    var 
      n = 0
      parent = record(sym"h", dict(@[(sym"k", list(num"1"))]))

    for c in parent.allChildren:
      inc n
    check n == 5

  test "find: first match in walk order, self first":
    let t = list(list(num"1"), num"2")
    check t.find(proc (x: Value): bool = x.isKind bNum) == some num"1"
    check t.find(proc (x: Value): bool = x.isKind bList) == some t
    check t.find(proc (x: Value): bool = x.isKind bBytes).isNone

suite "op outputs stay canonical":
  test "rebuilt frames round-trip the codec":
    let d = dict(@[(sym"a", num"1"), (sym"bb", num"2")])
    let outputs = [
      record(sym"point", num"3", num"4").map(
        proc (x: Value): Value = list(x)),
      d.map(proc (x: Value): Value = list(x)),
      d.filter(proc (x: Value): bool = x == num"2"),
      set(num"1", num"2").map(proc (x: Value): Value = sym"one"),
      d.transform(proc (x: Value): Value =
        (if x == sym"a": sym"zz" else: x)),
      mark(list(num"1")).map(proc (x: Value): Value = x),
    ]
    for v in outputs:
      check decode(encode(v)) == v

suite "composition":
  test "a file record reads through option chains and dialect types":
    let doc = toValue(BlFile(
      contents: @[byte 1, 2],
      info: some BlFileInfo(name: some "a.txt", zip: none Sym)))
    check doc.hasHead(sym"file")
    check doc[1] == some bytes(@[byte 1, 2])
    check doc[2].flatMap(
      proc (info: Value): Option[Value] = info[sym"name"]) == some text"a.txt"

  test "find a digest anywhere, then read it as a type":
    let held = list(sym"stuff",
                    record(sym"digest", sym"sha256", bytes(@[byte 0xAB])))
    let hit = held.find(proc (x: Value): bool = x.hasHead(sym"digest"))
    check hit.isSome
    let d = fromValue(hit.get, Digest)
    check d.isSome
    check d.get.algo == "sha256"
    check d.get.hash == @[byte 0xAB]