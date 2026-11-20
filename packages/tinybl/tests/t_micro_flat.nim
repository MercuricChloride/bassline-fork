import std/unittest
import tinybl/[micro, text]

suite "flat node access":
  test "preorder includes frames, record heads, dict keys and values":
    let root = toNode Value.parse"(a [b c] (d e [f g {h: i {j}: k}]))"
    let expected = @[
      root,
      Sym("a"),
      List(@[Sym("b"), Sym("c")]),
      Sym("b"), Sym("c"),
      toNode Value.parse"(d e [f g {h: i {j}: k}])",
      Sym("d"), Sym("e"),
      toNode Value.parse"[f g {h: i {j}: k}]",
      Sym("f"), Sym("g"),
      toNode Value.parse"{h: i {j}: k}",
      Sym("h"), Sym("i"), Set(@[Sym("j")]), Sym("j"), Sym("k")
    ]
    for i, node in expected:
      check root.atFlat(i) == node
    expect BasslineError:
      discard root.atFlat(expected.len)

  test "returns a borrow of the original node":
    let root = List(@[List(@[Sym("child")])])
    check unsafeAddr(root.atFlat(0)) == unsafeAddr(root)
    check unsafeAddr(root.atFlat(2)) ==
      unsafeAddr(root.asValue.nth(0).asValue.nth(0))

  test "empty frames and bound nodes each occupy one position":
    let live = Live().toNode
    let root = List(@[List(@[]), Set(@[]), Dict(@[]), live, Sym("last", true)])
    for i in 0..<root.asValue.len:
      check root.atFlat(i + 1) == root.asValue.nth(i)
    check root.atFlat(4).asLive == live.asLive
    expect BasslineError:
      discard root.atFlat(6)

  test "leaves have only position zero and negative positions refuse":
    for leaf in [Sym("atom"), toNode null(true), Live().toNode]:
      check leaf.atFlat(0) == leaf
      expect BasslineError:
        discard leaf.atFlat(1)
      expect BasslineError:
        discard leaf.atFlat(-1)

suite "flat node replacement":
  template node(s: string): Node = toNode Value.parse(s)

  test "replaces the root, a frame, a record head and a nested atom":
    var root = node("(a [b c] (d e))")
    root.setFlat(1, Sym("head", true))
    check root == node("(head! [b c] (d e))")
    root.setFlat(4, Sym("last"))
    check root == node("(head! [b last] (d e))")
    root.setFlat(2, List(@[]))
    check root == node("(head! [] (d e))")
    root.setFlat(0, Sym("root"))
    check root == Sym("root")

  test "reorders set members after a direct or nested replacement":
    var direct = node("{a b}")
    direct.setFlat(1, Sym("z"))
    check direct == node("{b z}")
    var nested = node("{[a] [b]}")
    nested.setFlat(2, Sym("z"))
    check nested == node("{[b] [z]}")

  test "reorders dict keys with their associated values":
    var direct = node("{a: 1 b: 2}")
    direct.setFlat(1, Sym("z"))
    check direct == node("{b: 2 z: 1}")
    var nested = node("{[a]: 1 [b]: 2}")
    nested.setFlat(2, Sym("z"))
    check nested == node("{[b]: 2 [z]: 1}")

  test "replaces dict values and restores the order of enclosing sets":
    var root = node("{{k: a} {k: b}}")
    root.setFlat(3, Sym("z"))
    check root == node("{{k: b} {k: z}}")

  test "duplicate set members refuse without changing the original":
    for original in [node("{a b}"), node("{[a] [b]}")]:
      var root = original
      expect BasslineError:
        root.setFlat(if original == node("{a b}"): 1 else: 2, Sym("b"))
      check root == original

  test "duplicate dict keys refuse without changing the original":
    for original in [node("{a: 1 b: 2}"), node("{[a]: 1 [b]: 2}")]:
      var root = original
      expect BasslineError:
        root.setFlat(if original == node("{a: 1 b: 2}"): 1 else: 2, Sym("b"))
      check root == original

  test "an outer collision undoes an inner reorder":
    let original = node("{{a b} {b c}}")
    var root = original
    root.setFlat(2, Sym("z"))
    check root == node("{{b c} {b z}}")
    root = original
    expect BasslineError:
      root.setFlat(2, Sym("c"))
    check root == original

  test "bound nodes and empty frames can be replaced, but not entered":
    let live = Live().toNode
    var root = List(@[live, List(@[]), Sym("end")])
    root.setFlat(1, Sym("plain"))
    root.setFlat(2, live)
    check root == List(@[Sym("plain"), live, Sym("end")])
    for index in [-1, 4, high(int)]:
      let original = root
      expect BasslineError:
        root.setFlat(index, Sym("invalid"))
      check root == original
    for leaf in [live, List(@[]), Sym("atom")]:
      var root = leaf
      expect BasslineError:
        root.setFlat(1, Sym("invalid"))
      check root == leaf
