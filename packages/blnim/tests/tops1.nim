import std/[unittest, sequtils]
import pkg/core
import pkg/lib/print

suite "at is the asking lens":
  let point = record(sym"point", num"3", num"4")
  let d = dict(@[(sym"a", num"1"), (sym"b", num"2")])

  test "positional at: the head is content":
    check point.at(num"0") == sym"point"
    check point.at(num"1") == num"3"
    check point.at(num"2") == num"4"
    expect ValueError:
      discard point.at(num"3")
    expect ValueError:
      discard point.at(num"-1")
    check list(num"9").at(num"0") == num"9"
    expect ValueError:
      discard num"5".at(num"0")

  test "keyed at: dicts are keyed, not positional":
    check d.at(sym"b") == num"2"
    expect ValueError:
      discard d.at(sym"z")
    expect ValueError:
      discard d.at(num"0")
    expect ValueError:
      discard num"5".at(sym"k")

  test "at by value: sets answer with their own element":
    let s = set(num"10", num"2", num"9")
    check s.at(num"2") == num"2"
    check s.at(num"9") == num"9"
    check s.at(num"10") == num"10"
    expect ValueError:
      discard s.at(num"3")

  test "probes answer, never refuse":
    check d.hasKey(sym"a")
    check not d.hasKey(sym"z")
    check not point.hasKey(sym"a")
    check not num"5".hasKey(sym"a")

suite "search is the spelling":
  let point = record(sym"point", num"3", num"4")
  let d = dict(@[(sym"a", num"1"), (sym"b", num"2")])

  test "contents: heads and keys included, document order":
    check toSeq(point.contents) == @[sym"point", num"3", num"4"]
    check toSeq(d.contents) == @[sym"a", num"1", sym"b", num"2"]
    # a scalar has no contents to spell, so asking is a caller error
    expect ValueError:
      discard toSeq(text"x".contents)

  test "children: a record's head stays out":
    check toSeq(point.children) == @[num"3", num"4"]
    check toSeq(d.children) == @[sym"a", num"1", sym"b", num"2"]
    check toSeq(list(num"1", num"2").children) == @[num"1", num"2"]

  test "pairs speak a dict's entries in canonical order":
    var ks, vs: seq[Value]
    for k, v in d.pairs:
      ks.add k
      vs.add v
    check ks == @[sym"a", sym"b"]
    check vs == @[num"1", num"2"]
    check pairsLen(d) == 2
    expect ValueError:
      for k, v in point.pairs:
        discard k

  test "contains: anything among the contents counts":
    let s = set(num"10", num"2", num"9")
    check num"2" in s and num"9" in s and num"10" in s
    check num"3" notin s
    check sym"point" in point # the head is content
    check num"3" in point
    check num"5" notin point
    check sym"a" in d # keys are content
    check num"1" in d # values are content
    check sym"z" notin d
    check sym"x" notin num"5" # scalars contain nothing

  test "find: the first admitted in walk order, or a refusal":
    check find(point, proc(v: Value): bool = v.kind == bNum) == num"3"
    expect ValueError:
      discard find(point, proc(v: Value): bool = v.kind == bBytes)

  test "findInto dumps every match into a draft":
    var hits = open(bList)
    findInto(point, proc(v: Value): bool = v.kind == bNum, hits)
    let got = close(move hits)
    check got == list(num"3", num"4")

suite "shallow rewriting is the content lens":
  let point = record(sym"point", num"3", num"4")
  let d = dict(@[(sym"a", num"1"), (sym"b", num"2")])

  test "map: open, transform, close — record head stays":
    let wrapped = close(map(open(point),
      proc(x: sink Value): Value =
        list(x)
    ))
    check wrapped == record(sym"point", list(num"3"), list(num"4"))
    check wrapped.head == sym"point"

  test "map: dict keys stay, values move; the fast door seals":
    let wrapped = seal(map(open(d),
      proc(x: sink Value): Value =
        list(x)
    ))
    check wrapped == dict(@[(sym"a", list(num"1")), (sym"b", list(num"2"))])

  test "map: a list rewrites every element":
    let got = close(map(open(list(num"1", num"2")),
      proc(x: sink Value): Value =
        list(x)
    ))
    check got == list(list(num"1"), list(num"2"))

  test "map: sets remint through close, collisions dedupe":
    let collapsed = close(map(open(set(num"1", num"2", num"3")),
      proc(x: sink Value): Value =
        sym"one"
    ))
    check collapsed == set(sym"one")

  test "scalars have no draft: opening one refuses":
    expect ValueError:
      discard open(num"5")

  test "marks survive the open/transform/close round trip":
    let got = close(map(open(mark(list(num"1"))),
      proc(x: sink Value): Value =
        x
    ))
    check got.marked

  test "a raising callback destroys the in-flight draft":
    var b = open(list(num"1", num"2"))
    expect ValueError:
      discard map(move b,
        proc(x: sink Value): Value =
          raise newException(ValueError, "no")
      )
    # b was consumed at the call: what the caller still holds is a
    # moved-from draft, and the door refuses it — husks are
    # unreachable
    expect ValueError:
      discard close(move b)

  test "filter: the head survives a reject-all pred":
    let got = close(filter(open(point),
      proc(x: Value): bool =
        false
    ))
    check got == record(sym"point")

  test "filter: dict entries kept by their value":
    let got = seal(filter(open(d),
      proc(x: Value): bool =
        x == num"2"
    ))
    check got == dict(@[(sym"b", num"2")])

  test "filter: a sorted subset of a set seals":
    let got = seal(filter(open(set(num"1", num"2", num"3")),
      proc(x: Value): bool =
        x != num"2"
    ))
    check got == set(num"1", num"3")

  test "filter: lists compact in place":
    let got = close(filter(open(list(num"1", num"2")),
      proc(x: Value): bool =
        x == num"1"
    ))
    check got == list(num"1")

  test "filter never judges: a malformed tail survives for the door":
    var b = open(bDict)
    b.add(sym"complete", num"1")
    b.add sym"orphan"
    var kept = filter(move b,
      proc(x: Value): bool =
        true
    )
    check kept.len == 3
    expect ValueError:
      discard seal(move kept)

  test "filtering an empty record draft leaves the verdict to the door":
    var kept = filter(open(bRecord),
      proc(x: Value): bool =
        true
    )
    expect ValueError:
      discard close(move kept)

suite "open frames: drafts are free, the door judges":
  test "open a kind, feed, close":
    var b = open(bList)
    b.add num"1"
    b.add num"2"
    let got = close(move b)
    check got == list(num"1", num"2")

  test "explode keeps the mark and the original container":
    var b = open(mark(record(sym"h", num"1")))
    check b.kind == bRecord
    check b.marked
    check b.len == 2
    b.add num"9"
    let got = close(move b)
    check got == mark(record(sym"h", num"1", num"9"))

  test "rekind: a draft may still choose its framing":
    var b = open(list(sym"a", num"1", sym"b", num"2"))
    b.rekind(bDict)
    let got = close(move b)
    check got == dict(@[(sym"a", num"1"), (sym"b", num"2")])

  test "close establishes what seal only verifies":
    var b = open(bSet)
    b.add num"2"
    b.add num"1"
    b.add num"2"
    let got = close(move b)
    check got == set(num"1", num"2")

    var c = open(bSet)
    c.add num"2"
    c.add num"1"
    expect ValueError:
      discard seal(move c)

    var dd = open(bDict)
    dd.add(sym"a", num"1")
    dd.add(sym"a", num"2")
    expect ValueError:
      discard close(move dd)

    var r = open(bRecord)
    expect ValueError:
      discard close(move r)

  test "take moves out and a husk stays behind the cursor":
    var b = open(list(num"1", num"2"))
    check b.take(0) == num"1"
    check b.len == 2
    check b[0] == Nil
    check b[1] == num"2"
    expect ValueError:
      discard b.take(9)

  test "mchildren rewrites children in place":
    var b = open(list(num"1", num"2"))
    for x in b.mchildren:
      x = list(move x)
    let got = close(move b)
    check got == list(list(num"1"), list(num"2"))

  test "mpairs rewrites entry values; keys are read-only there":
    var b = open(dict(@[(sym"a", num"1"), (sym"b", num"2")]))
    for k, v in b.mpairs:
      v = list(move v)
    let got = seal(move b)
    check got == dict(@[(sym"a", list(num"1")), (sym"b", list(num"2"))])


suite "the algebra takes drafts":
  test "merge: dicts refuse a shared key, sets union":
    let m = close merge(
      open(dict(@[(sym"a", num"1")])), open(dict(@[(sym"b", num"2")]))
    )
    check m == dict(@[(sym"a", num"1"), (sym"b", num"2")])
    expect ValueError:
      # merge feeds; the collision is the door's judgment
      discard close merge(
        open(dict(@[(sym"a", num"1")])), open(dict(@[(sym"a", num"2")]))
      )
    let u = close merge(open(set(num"1", num"2")), open(set(num"2", num"3")))
    check u == set(num"1", num"2", num"3")
    expect ValueError:
      discard merge(open(list(num"1")), open(list(num"2")))

  test "the join is total over unjudged drafts":
    var x = open(bDict)
    x.add(sym"b", num"2")
    x.add(sym"a", num"1") # unsorted on purpose
    var y = open(bDict)
    y.add(sym"c", num"3")
    let m = close merge(move x, move y)
    check m == dict(@[(sym"a", num"1"), (sym"b", num"2"), (sym"c", num"3")])

  test "difference: whole entries for dicts, members for sets":
    let dd = seal difference(
      open(dict(@[(sym"a", num"1"), (sym"b", num"2")])),
      open(dict(@[(sym"a", num"1"), (sym"b", num"9")])),
    )
    check dd == dict(@[(sym"b", num"2")])
    let sd = seal difference(
      open(set(num"1", num"2", num"3")), open(set(num"2"))
    )
    check sd == set(num"1", num"3")

  test "put: last wins; the door places the new key":
    let d0 = dict(@[(sym"a", num"1"), (sym"c", num"3")])
    check close(put(open(d0), sym"a", num"9")) ==
      dict(@[(sym"a", num"9"), (sym"c", num"3")])
    check close(put(open(d0), sym"b", num"2")) ==
      dict(@[(sym"a", num"1"), (sym"b", num"2"), (sym"c", num"3")])
    let point = record(sym"point", num"3", num"4")
    check close(put(open(point), num"0", sym"origin")) ==
      record(sym"origin", num"3", num"4")
    expect ValueError:
      discard put(open(point), num"9", sym"x")
    expect ValueError:
      discard put(open(set(num"1")), num"1", num"2")

  test "keys and vals cast a dict draft":
    let d2 = dict(@[(sym"b", num"1"), (sym"a", num"1")])
    check seal(keys(open(d2))) == set(sym"a", sym"b")
    check close(vals(open(d2))) == set(num"1") # collisions dedupe
    expect ValueError:
      discard keys(open(list()))
