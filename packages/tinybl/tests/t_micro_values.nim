import std/[os, sequtils, unittest]
import tinybl

type
  File = ref object of Live
    path: string

  Folder = ref object of Live
    files: seq[File]

method reified(self: File): Value =
  let path = Text(self.path)
  toValue bl"!(file $path)"

method reified(self: Folder): Value =
  let files = self.files.mapIt(it.toNode)
  toValue bl"!(folder @files)"

let
  a = File(path: getTempDir() / "t_micro_values_a.txt")
  b = File(path: getTempDir() / "t_micro_values_b.txt")

for f in [a, b]:
  f.path.writeFile("")

suite "live nodes":
  test "a live node sorts after every plain one and equals only itself":
    let
      plain = Num(0)
      live = Live().toNode
      other = Live().toNode
    check plain < live
    check plain != live
    check live == live
    check live != other

  test "a live member is the host object it was made from":
    let held = List(@[a.toNode, b.toNode])
    check not held.isPure
    check File(held[0].asLive) == a
    File(held[0].asLive).path.writeFile("hello")
    check a.path.readFile == "hello"

  test "reified reads every live member as its value":
    let held = Set(@[a.toNode, b.toNode])
    check held.reified == Set(@[a.reified.toNode, b.reified.toNode])
    check held.reified.isPure

  test "reify goes one level unless it goes deep":
    let folder = Folder(files: @[a, b]).toNode
    var once = folder
    once.reify
    check not once.isPure
    check once[1] == a.toNode
    var deep = folder
    deep.reify(deep = true)
    check deep.isPure
    check deep == folder.reified

  test "a node is written once it is reified, and reads back the same":
    let folder = Folder(files: @[a, b]).toNode
    var refused: string
    expect BasslineError:
      folder.write(refused)
    var bytes: string
    folder.reified.write(bytes)
    var reader = initReader()
    check reader.readOne(bytes).toNode == folder.reified

for f in [a, b]:
  f.path.removeFile
