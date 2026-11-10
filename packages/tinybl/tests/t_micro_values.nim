import std/unittest
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

proc exampleValue(): Value =
  BuildValue.frame(@[
    toValue File(path: "/tmp/foo.bar"),
    toValue File(path: "/tmp/foo.bar")
  ], bSet, false)

test "can reify":
  let 
    foo = exampleValue()
    bar = foo.reify
  check not foo.isPureData
  check bar.isPureData
  check foo.len == 2
  check bar.len == 1

test "can round trip":
  let foo = exampleValue()
  var
    s = ""
    reader = initReader(BuildValue)
  foo.write(s)
  for one in reader.readEach(s):
    check one == foo.reify
    check one != foo