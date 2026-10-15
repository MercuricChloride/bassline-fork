## fs: files as values, the keep, and reading content back through
## searches

import std/[unittest, options, os, posix, sequtils, strutils, random, algorithm]
import bl/[core, queries]
import bl/lib/fs

let scratch = getTempDir() / "tfs-" & $getCurrentProcessId()
removeDir(scratch)
createDir(scratch)

proc randomBytes(n: int, seed: int): seq[byte] =
  var r = initRand(seed)
  result = newSeq[byte](n)
  for b in result.mitems: b = byte(r.rand(255))

proc emptyKeep(name: string): Keep =
  openKeep(scratch / name & ".blb")

suite "content":
  test "cuts cover every byte once, in order, within the bounds":
    let data = randomBytes(500_000, 1)
    var next = 0
    for (first, last) in cuts(data):
      check first == next
      check last - first + 1 <= 64 * 1024
      next = last + 1
    check next == data.len

  test "the same bytes cut the same way, and an edit moves only nearby cuts":
    let data = randomBytes(400_000, 2)
    var edited = data
    edited.insert([1'u8, 2, 3], 200_000)
    let a = cuts(data).toSeq
    let b = cuts(edited).toSeq
    check a == cuts(data).toSeq
    check a[0] == b[0]
    check a[^1][1] + 3 == b[^1][1]
    check (a[^1][1] - a[^1][0]) == (b[^1][1] - b[^1][0])

  test "a small file is its bytes atom":
    let (content, chunks) = contentOf([1'u8, 2, 3])
    check content == bytes([1'u8, 2, 3])
    check chunks.len == 0

  test "a large file is a manifest of its chunks, each verifying":
    let data = randomBytes(300_000, 3)
    let (content, chunks) = contentOf(data)
    check content.isKind(bRec)
    check content.head == sym"chunks"
    check content.items[1] == toValue(data.len)
    check content.items[2].items.data.zip(chunks).allIt(verifies(it[0], it[1]))
    check verifies(digestOf(content), content)
    check not verifies(digestOf(content), chunks[0])

  test "the cut is pinned: the content digests blts makes too":
    check digestOf(contentOf(newSeq[byte](200_000)).content) ==
      rv"(digest blake2b 0x64d5fed95a5412f135203c0122715d5e800b8f4ba18f842bf59a9523ae3f51bc)"
    let text = "the quick brown fox jumps over the lazy dog\n".repeat(8000)
    check digestOf(contentOf(text.toOpenArrayByte(0, text.high)).content) ==
      rv"(digest blake2b 0xb3cc5570867c31a48b160475143a4d79212c0ab6350fdbb1617f87a100ef62b3)"

suite "the keep":
  test "stores once, fetches what verifies, and holds across opening again":
    let k = emptyKeep("once")
    let v = rv"(hello [1 2 3])"
    let d = k.store(v)
    check d == digestOf(v)
    check k.store(v) == d
    check getFileSize(scratch / "once.blb") == v.ce.len
    check k.fetch(d) == some(v)
    check k.fetch(digestOf(rv"other")).isNone
    k.close()
    let again = emptyKeep("once")
    check again.holds(d)
    check again.held == @[d]

  test "two keeps on one file see each other's values":
    let a = emptyKeep("shared")
    let b = emptyKeep("shared")
    let d = a.store(rv"from-a")
    check b.holds(d)
    let e = b.store(rv"from-b")
    check a.fetch(e) == some(rv"from-b")

  test "a value cut short is cut off before the next is written":
    let path = scratch / "torn.blb"
    let whole = rv"whole".ce
    writeFile(path, cast[string](whole & rv"(cut short)".ce[0 .. 3]))
    let k = openKeep(path)
    check k.held.len == 1
    discard k.store(rv"next")
    check getFileSize(path) == whole.len + rv"next".ce.len
    check emptyKeep("torn").held.len == 2

suite "trees":
  let src = scratch / "src"
  createDir(src / "sub" / "deeper")
  writeFile(src / "small.txt", "hello\n")
  writeFile(src / "big.bin", cast[string](randomBytes(200_000, 4)))
  writeFile(src / "sub" / "deeper" / "note.md", "# note\n")
  createSymlink("small.txt", src / "link")
  setFilePermissions(src / "small.txt", {fpUserRead, fpUserWrite, fpUserExec})

  test "adding and writing out gives back the same tree":
    let k = emptyKeep("tree")
    let e = k.add(src)
    check e.head == sym"dir"
    let s = checked(keepSearch(k))
    check s.missing(named(e).get).len == 0
    s.writeOut(e, scratch / "out")
    for f in ["small.txt", "big.bin", "sub/deeper/note.md"]:
      check readFile(scratch / "out" / f) == readFile(src / f)
    check expandSymlink(scratch / "out" / "link") == "small.txt"
    check fpUserExec in getFilePermissions(scratch / "out" / "small.txt")

  test "the same tree added again stores nothing more":
    let k = emptyKeep("again")
    let e = k.add(src)
    let size = getFileSize(scratch / "again.blb")
    check k.add(src) == e
    check getFileSize(scratch / "again.blb") == size

  test "a tree under another name keeps its digest":
    let k = emptyKeep("renamed")
    copyDir(src / "sub", scratch / "elsewhere")
    let s = checked(keepSearch(k))
    let inSrc = s.walk(k.add(src), ["sub"]).toSeq
    check inSrc.len == 1
    check named(inSrc[0]) == named(k.add(scratch / "elsewhere"))

  test "listing and walking":
    let k = emptyKeep("walk")
    let e = k.add(src)
    let s = checked(keepSearch(k))
    check s.listing(e).get.mapIt(it[0]).sorted == @["big.bin", "link", "small.txt", "sub"]
    let note = s.walk(e, ["sub", "deeper", "note.md"]).toSeq
    check note.len == 1
    check s.bytesOf(named(note[0]).get) == some(@(cast[seq[byte]]("# note\n")))
    check s.walk(e, ["sub", "nothing"]).toSeq.len == 0
    check s.walk(named(e).get, ["small.txt"]).toSeq.len == 1

  test "missing says what another keep would have to give":
    let full = emptyKeep("full")
    let e = full.add(src)
    let part = emptyKeep("part")
    let d = named(e).get
    discard part.store(full.fetch(d).get)
    let s = checked(keepSearch(part))
    let lacking = s.missing(d)
    check lacking.len == 3 # small.txt, big.bin's manifest, sub's tree
    check checked(keepSearch(part), keepSearch(full)).missing(d).len == 0
    expect BasslineError:
      s.writeOut(e, scratch / "partial")
    check not dirExists(scratch / "partial")

  test "checked passes over answers a digest isn't of":
    let k = emptyKeep("liar")
    let real = rv"real"
    let liar = newSearch[Value, Value]((d: Value) => just(rv"forged"))
    let s = checked(liar, keepSearch(k))
    discard k.store(real)
    check s.ask(digestOf(real)).toSeq == @[real]

  test "the readers check every answer whatever search they are given":
    let liar = newSearch[Value, Value]((d: Value) => just(bytes([6'u8, 6, 6])))
    let d = digestOf(bytes([1'u8]))
    check liar.bytesOf(d).isNone
    check liar.missing(d) == @[d]
    check liar.walk(d, ["x"]).toSeq.len == 0

  test "modes are written without setuid, setgid or sticky":
    let k = emptyKeep("modes")
    let content = k.addBytes([1'u8, 2])
    let e = FileEntry(content: Digest.load(content), size: 2, mode: 0o4755).mold
    checked(keepSearch(k)).writeOut(e, scratch / "setuid")
    var st: Stat
    check stat((scratch / "setuid").cstring, st) == 0
    check (int(st.st_mode) and 0o7777) == 0o755

  test "checked answers a value once however many sources hold it":
    let a = emptyKeep("twice-a")
    let b = emptyKeep("twice-b")
    let e = a.add(src)
    discard b.add(src)
    let s = checked(keepSearch(a), keepSearch(b))
    check s.ask(named(e).get).toSeq.len == 1
    check s.walk(e, ["sub", "deeper", "note.md"]).toSeq.len == 1

  test "a directory that can't be read is skipped, not added as empty":
    let k = emptyKeep("unreadable")
    let dir = scratch / "locked"
    createDir(dir / "shut")
    writeFile(dir / "open.txt", "open\n")
    setFilePermissions(dir / "shut", {})
    var skipped: seq[string]
    let e = k.add(dir, (path, why: string) => skipped.add path)
    setFilePermissions(dir / "shut", {fpUserRead, fpUserWrite, fpUserExec})
    check skipped == @[dir / "shut"]
    check checked(keepSearch(k)).listing(e).get.mapIt(it[0]) == @["open.txt"]

  test "a mode that isn't one is refused":
    let k = emptyKeep("badmode")
    let content = k.addBytes([1'u8])
    let e = FileEntry(content: Digest.load(content), size: 1, mode: -1).mold
    expect BasslineError:
      checked(keepSearch(k)).writeOut(e, scratch / "badmode")
    check not fileExists(scratch / "badmode")

  test "a bare digest inside a tree is walked through no more than written out":
    let k = emptyKeep("bare")
    let inner = k.store(FsTree(entries: @[("f", rv"(link x)")]).mold)
    let outer = k.store(FsTree(entries: @[("d", inner)]).mold)
    let s = checked(keepSearch(k))
    check s.walk(outer, ["d"]).toSeq == @[inner]
    check s.walk(outer, ["d", "f"]).toSeq.len == 0

removeDir(scratch)
