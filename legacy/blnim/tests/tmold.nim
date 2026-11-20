## mold: structs read from and written as values, by name, in either
## form; probes; conversion by name; Poly; the hooks; and the laws a face
## and a probe keep

import std/[unittest, random, strutils]
import bl/[core, mold]
import bl/lib/blah

moldable """{
  (struct digest {exact (rep record)}
    (algo (symbol {(one-of sha256 blake2b)}))
    (hash (bytes {(len 4)})))
  (struct file {(nim Entry)} (path symbol) (size number) (d digest)
    (tag {optional} symbol))
  !(struct shelf
    (name text) (tags !{symbol!}) (meta dict) (any-thing any) (val value!)
    (grid [[number]]) (index {symbol: [file]}) (top {optional} file)
    (new-count number))
  (struct note (text text) (tag {optional} symbol))
  (struct other (text text))
  (struct pair {(rep record)} (a number) (b number))
  (struct ab (a number) (b number) (c {optional} number))
  (struct strict {exact} (a number))
  (struct box (a any) (b {optional} any) (n number))
  (struct tray {(rep record)} (a any) (b {optional} any) (n number))
}"""

# hooks, written by hand over generated types
moldable """{
  (struct temperature (celsius number))
  (struct guarded (n number))
}"""

type Kelvin = ref object of Temperature
  kelvin: int # held here only: never molded, never loaded

var loads = 0

method beforeMold(self: Kelvin) =
  self.celsius = toNum(self.kelvin - 273)

method afterLoad(self: Kelvin) =
  inc loads
  self.kelvin = self.celsius.toInt + 273

method afterLoad(self: Guarded) =
  if self.n.toInt < 0: raise newException(MoldError, "n must not be negative")

template refuses(call: untyped) =
  ## the reading raises rather than holding what it can't
  expect MoldError:
    discard call

let
  d = Digest(algo: "sha256", hash: [1'u8, 2, 3, 4])
  f = Entry(path: "/p", size: 3, d: d)

suite "the two forms":
  test "a struct is written as a dict, or as a record in field order":
    check $f.moldDict == "(file {d: (digest sha256 0x01020304) path: /p size: 3})"
    check $f.moldRec == "(file /p 3 (digest sha256 0x01020304) nil)"
    check f.mold == f.moldDict
    check d.mold == d.moldRec

  test "each form reads back what it wrote, by name either way":
    check Entry.loadDict(f.moldDict).mold == f.mold
    check Entry.loadRec(f.moldRec).mold == f.mold
    check Digest.loadDict(d.moldDict).mold == d.mold

  test "nil in a record is an optional field with nothing in it":
    check Note.loadRec(rv"""(note "t" nil)""").tag.isNone
    check Note.loadRec(rv"""(note "t" x)""").tag == some "x"
    refuses Pair.loadRec(rv"(pair nil 2)")

  test "every TYPE, marked or not, round trips":
    let s = Shelf(name: "top", tags: @["x"], meta: rv"{a: 1}".dict,
                  anyThing: rv"x!", val: rv"!(v)", grid: @[@[1.toNum]],
                  index: @[("k", @[f])], newCount: 2)
    check s.mold.mark
    check Shelf.load(s.mold).mold == s.mold
    check Shelf.loadRec(s.moldRec).mold == s.mold
    check "new-count: 2" in $s.mold

  test "a struct says its shape":
    check Shelf.head == sym"shelf"
    check Shelf.marked
    check Entry.shape.names == @[sym"path", sym"size", sym"d", sym"tag"]
    check readValue(Entry.shape.description) ==
      rv"(struct file {(nim Entry) (rep dict)} (path symbol) (size number) (d digest) (tag {optional} symbol))"

suite "refusals":
  test "what doesn't fit the description is refused":
    refuses Digest.load(rv"(digest rsa 0x01020304)")          # not one of
    refuses Digest.load(rv"(digest sha256 0x0102)")           # not 4 bytes
    refuses Digest.load(rv"!(digest sha256 0x01020304)")      # marked
    refuses Digest.load(rv"(nope sha256 0x01020304)")         # another head
    refuses Note.load(rv"(note {tag: x})")                    # a field missing
    refuses Note.load(rv"""(note {text: 1})""")               # the wrong kind
    refuses Shelf.load(f.mold)                                # unmarked

  test "read exactly, a field or item more is refused":
    refuses Digest.load(rv"(digest sha256 0x01020304 more)")
    refuses Digest.loadDict(rv"(digest {algo: sha256 hash: 0x01020304 x: 1})")
    refuses Strict.load(rv"(strict {a: 1 b: 2})")
    check Note.load(rv"""(note {text: "t" more: 1})""").text == "t"

  test "what can't be written is refused too":
    refuses Digest(algo: "rsa").mold
    refuses Entry(path: "/p", size: 1).mold         # d has nothing in it

  test "a load that refuses sets nothing":
    var n = Note(text: "old")
    expect MoldError: n.load(rv"""(note {text: "new" tag: "not a symbol"})""")
    check n.text == "old"

suite "conversion":
  test "fields carry over by name; the rest is left behind":
    check $Pair(a: 1, b: 2).convert(Ab).mold == "(ab {a: 1 b: 2})"
    check $Ab(a: 1, b: 2, c: some 3.toNum).convert(Pair).mold == "(pair 1 2)"
    refuses Other(text: "x").convert(Pair)

suite "poly":
  test "a field a face leaves out is left out":
    let p = poly Note(text: "a", tag: some "urgent")
    discard p[Other]
    let n = p[Note]
    n.tag = none string
    discard p[Other]
    check p[Note].tag.isNone
    check $p.toValue == """(note {text: "a"})"""

  test "faces share fields by name, and the rest is kept":
    let p = poly Note(text: "b", tag: some "kept")
    p[Other].text = "edited"
    check p[Note].text == "edited"
    check p[Note].tag == some "kept"

  test "a face handed out before a switch is no longer heard from":
    let p = poly Note(text: "a")
    let stale = p[Note]
    discard p[Other]
    stale.text = "unheard"
    check p[Note].text == "a"

suite "hooks":
  test "afterLoad runs once, when a value is first read":
    loads = 0
    let k = Kelvin.load(rv"(temperature {celsius: 20})")
    check k.kelvin == 293
    check loads == 1
    k.load(rv"(temperature {celsius: 30})") # read again: not the first time
    check loads == 1
    check k.celsius.toInt == 30

  test "beforeMold runs before every write":
    let k = Kelvin(kelvin: 300)
    check $k.mold == "(temperature {celsius: 27})"
    k.kelvin = 310
    check $k.moldFields.initDict == "{celsius: 37}"

  test "afterLoad may refuse":
    check Guarded.load(rv"(guarded {n: 1})").n.toInt == 1
    refuses Guarded.load(rv"(guarded {n: -1})")

suite "laws: a face over generated values":
  setup:
    randomize(7)

  test "a struct reads back what it wrote, in either form":
    for _ in 0 ..< 300:
      let b = Box(a: randValue(4), n: rand(-1000 .. 1000))
      if rand(1) == 1: b.b = some randValue(4)
      check Box.load(b.mold).mold == b.mold
      if b.b.isSome and b.b.get == null():
        refuses b.moldRec # nil, which a record can't tell from nothing
      else:
        check Box.loadRec(b.moldRec).mold == b.mold

  test "get-put: a face read and written back unchanged leaves the bytes":
    for _ in 0 ..< 300:
      let fields = initDict(@[(sym"a", randValue(4)), (sym"n", num(rand(100))),
                              (sym"other", randValue(4))])
      let p = poly fields
      discard p[Box]
      check p.toDict == fields

  test "put-get: what a face wrote is what it reads back":
    for _ in 0 ..< 300:
      let p = poly Box(a: randValue(4), n: 1)
      let b = p[Box]
      b.a = randValue(4)
      b.b = if rand(1) == 1: some randValue(4) else: none Value
      let written = b.moldFields.initDict
      discard p[Tray]
      discard p.toDict
      check Box.loadFields(p.toDict.dict).moldFields.initDict == written

  test "asking for another face changes nothing until a face does":
    for _ in 0 ..< 300:
      let p = poly Box(a: randValue(4), n: rand(9), b: some randValue(4))
      let before = p.toDict
      discard p[Tray]
      discard p[Box]
      check p.toDict == before

suite "probes":
  test "a probe checks what a load would, and keeps nothing":
    check Entry.fits(f.mold)
    check Digest.fits(d.mold)
    check not Digest.fits(rv"(digest rsa 0x01020304)")
    check not Entry.fits(f.moldRec) # not its own form
    Entry.probeRec(f.moldRec)
    Entry.probeFields(f.moldFields)
    expect MoldError: Note.probe(rv"(note {tag: x})")

  test "a hook is heard only from a load":
    check Guarded.fits(rv"(guarded {n: -1})")
    check Guarded.maybeLoad(rv"(guarded {n: -1})").isNone

proc mutated(v: Value): Value =
  ## v with one part of it changed somewhere, or v itself
  let r = rand(9)
  if r == 0: return randValue(4)
  if r == 1:
    result = v
    result.mark = not v.mark
    return
  case v.kind
  of bRec, bList:
    var items = v.items.data
    if items.len == 0: return v
    let i = rand(items.high)
    if r == 2 and i > 0: items.delete(i)
    elif r == 3: items.add randValue(4)
    else: items[i] = mutated(items[i])
    if v.kind == bRec: initRec(items, v.mark) else: initList(items, v.mark)
  of bDict:
    var entries: seq[(Value, Value)]
    for k, x in v.dict: entries.add (k, x)
    if entries.len == 0 or r == 3: entries.add (randValue(4), randValue(4))
    else:
      let i = rand(entries.high)
      if r == 2: entries.delete(i) else: entries[i][1] = mutated(entries[i][1])
    initDict(entries, v.mark)
  else: v

template said(body: untyped): string =
  ## what a reading refuses with; nothing where it doesn't
  try:
    body
    ""
  except MoldError as e:
    e.msg

proc loadsDict[T: Moldable](_: type T, v: Value) = discard T.loadDict(v)
proc loadsRec[T: Moldable](_: type T, v: Value) = discard T.loadRec(v)

proc probesAsItLoads[T: Moldable](_: type T, v: Value): bool =
  said(T.loadsDict(v)) == said(T.probeDict(v)) and
    said(T.loadsRec(v)) == said(T.probeRec(v))

suite "laws: probes":
  setup:
    randomize(11)

  test "a probe refuses where a load refuses, in the same words":
    let shelf = Shelf(name: "s", tags: @["a", "b"], meta: rv"{k: 1}".dict,
                      anyThing: rv"x!", val: rv"!(v)", grid: @[@[1.toNum]],
                      index: @[("k", @[f])], top: some f, newCount: 2)
    let seeds = [f.mold, f.moldRec, d.mold, d.moldDict, shelf.mold,
                 shelf.moldRec, Note(text: "t", tag: some "x").mold,
                 Strict(a: 1).mold, Pair(a: 1, b: 2).mold,
                 Box(a: rv"[1]", b: some rv"x", n: 3).mold,
                 Tray(a: rv"{}", n: 3).mold]
    var read, refused = 0
    for _ in 0 ..< 3000:
      var v = seeds[rand(seeds.high)]
      for _ in 0 .. rand(2): v = mutated(v)
      let ok = Entry.probesAsItLoads(v) and Digest.probesAsItLoads(v) and
        Shelf.probesAsItLoads(v) and Note.probesAsItLoads(v) and
        Strict.probesAsItLoads(v) and Pair.probesAsItLoads(v) and
        Box.probesAsItLoads(v) and Tray.probesAsItLoads(v)
      check ok
      if not ok: checkpoint $v
      if Shelf.fits(v) or Entry.fits(v): inc read else: inc refused
    check read > 100 and refused > 100
