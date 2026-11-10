import std/[unittest, os]
import tinybl/micro/[ce, values]

test "a live value is always > a node value":
  let
    data = Data(data: Node(kind: bNum))
    live = Bound(live: Live())
    other = live
  
  check data < live
  check data != live
  check data < other
  check live == other

type
  File = ref object of Live
    path: string

template sym(t): untyped =
  BuildValue.atom(t, bSym, false)

method reify(self: File): Node =
  var items = @[
    sym("file"),
    sym(self.path)
  ]
  Node(vseq: items, kind: bRec, mark: true)

method write(self: File, s: string) =
  self.path.expandFilename.writeFile(s)

method resolve(self: File): string =
  self.path.expandTilde.readFile

proc exampleValue(): Value =
  BuildValue.frame(@[
    toValue File(path: "/tmp/foo.txt"),
    toValue File(path: "/tmp/foo.txt")
  ], bSet, false)

test "can reify":
  let 
    foo = exampleValue()
    bar = foo.reify
  check not foo.isPureData
  check bar.isPureData
  check foo.asNode.len == 2
  check bar.len == 1
  let f = File(foo.node.getChild(0).asLive)
  let old = f.resolve
  echo "content: ", old
  f.write("hello from the test")
  echo f.resolve
  f.write(old)
  echo f.resolve

test "round trips":
  let foo = exampleValue()
  var
    s = ""
    reader = initReader(BuildValue)
  foo.write(s)
  let one = reader.readOne(s)

  check one.node == foo.reify
  # this should fail because foo.node won't reify the files
  check one.node != foo.node
  check one != foo