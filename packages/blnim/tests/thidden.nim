## hidden: a value by the digest of its own tree, any part shown with a
## log-size path against the digest alone, or a signature over it

import std/[options, sequtils, unittest]
import bl/[core, queries]
import bl/lib/[blah, evidence, hidden, jam]
import bl/lib/crypto/[clave, digest]

proc seed(n: byte): Keypair =
  var s: Seed
  for i in 0 ..< 32: s[i] = n
  keypairFromSeed(s)

proc d(v: Value): Value = digest(v, Blake2bAlgo).toValue

template refuses(call: untyped) =
  expect MoldError:
    discard call

proc paths(v: Value, here: seq[int] = @[]): seq[(seq[int], Value)] =
  ## every place in `v` with what sits there, the way `hide` descends
  result.add (here, v)
  if v.kind in {bList, bRec, bDict, bSet} and v.len > 0:
    for i, p in toSeq(v.parts): result.add paths(p, here & i)

proc runRoot(t: Tree): Value =
  ## (root N D) over the nodes of t's parts
  Root(count: t.parts.len, digest: treeRoot(t.parts.mapIt(it.digest))).toValue

proc onlySets(v: Value): bool = v.kind == bSet

proc withSteps(s: Shown, steps: seq[Value]): Value =
  let (h, node) = (s.hidden, s.node)
  bl"(shown $h $steps $node)"

proc withNode(s: Shown, node: Value): Value =
  let (h, steps) = (s.hidden, s.steps)
  bl"(shown $h $steps $node)"

let invoice = bl"""(invoice (to "alice") (amount 42) {sealed paid})"""

suite "nodes":
  test "a part hidden whole is evidence's leaf, so the trees agree":
    for v in [bl"1", toValue("x"), readValue("go!"), bl"""(to "alice")""", readValue("!(do it)")]:
      check nodeDigest(leaf(v)) == rootDigest([v])
      check hide(v, apart = never).digest == rootDigest([v])
    check hide(bl"1").parts.len == 0 and hide(bl"""(to "alice")""").parts.len == 2

  test "a frame hidden by its parts is (KIND (root N D)) over its parts' nodes, marked as it is":
    let t = hide(invoice)
    let r = t.runRoot
    check t.node == bl"(record $r)"
    check t.parts.len == 4 and t.parts[0].node == leaf(bl"invoice")
    let f = frameOf(t.node).get
    check f.kind == bRec and not f.mark and f.root.count.toInt == 4
    let m = hide(readValue("!(do 1 2)"))
    check m.node.mark and frameOf(m.node).get.mark
    check m.node == readValue("!(record " & $m.runRoot & ")")
    check hide(readValue("!(do 1 2)")).digest != hide(readValue("(do 1 2)")).digest

  test "a set hidden by its parts, its members whole, is exactly the tree an opening is checked against":
    let s = bl"""{1 "two" three [4]}"""
    let t = hide(s, apart = onlySets)
    let members = toSeq(s.members)
    check frameOf(t.node).get.root.toValue == root(members).toValue
    let p = inclusion(members, 2)
    check p.holds and p.root.digest == frameOf(t.node).get.root.digest

  test "a dict's parts run keys before values; a frame with no parts is hidden whole":
    let t = hide(bl"{a: 1 b: 2}")
    check t.parts.len == 4
    check t.parts.mapIt(leafOf(it.node).get) == @[bl"a", bl"1", bl"b", bl"2"]
    for e in [bl"[]", bl"{}", readValue("{:}")]:
      check hide(e).node == leaf(e)
      check hide(e).parts.len == 0
    check hide(bl"(x)").parts.len == 1       # a record always has its head

  test "which frames are hidden apart is the hider's choice":
    let whole = hide(invoice, apart = v => not v.isKind(bSet))
    check whole.parts[3].node == leaf(bl"{sealed paid}")
    check whole.parts[3].parts.len == 0
    check whole.shown([3]).part == some bl"{sealed paid}"
    refuses whole.shown([3, 0])

suite "shown":
  test "every part of every small value is shown with a path that holds and gives it back":
    for v in [invoice, bl"[1 [2 [3 [4]]]]", bl"{k: [a b] j: {c: d}}"]:
      let t = hide(v)
      for (path, part) in paths(v):
        let s = t.shown(path)
        check s.holds and s.depth == path.len
        check Shown.fromValue(s.toValue).holds
        if hide(part).parts.len == 0:
          check s.part == some part
        else:
          check s.part.isNone and frameOf(s.node).get.kind == part.kind
    for _ in 0 ..< 20:
      let v = randValue(3)
      let t = hide(v)
      for (path, part) in paths(v):
        check t.shown(path).holds

  test "a place is a step without its siblings, marked as the frame is":
    let t = hide(readValue("!(do [1 2] 3)"))
    let s = t.shown([1, 1])
    check s.places == readValue("[!(record 3 1) (list 2 1)]")
    check s.way.mapIt(it.place) == s.places.items.data
    check hide(invoice).shown([]).places == bl"[]"

  test "a shown is logarithmic in each frame's width, never the width":
    var wide: seq[Value]
    for i in 0 ..< 1024: wide.add toValue(i)
    let t = hide(initList(@[initList(wide), bl"0"]))
    let s = t.shown([0, 511])
    check s.holds and s.part == some bl"511"
    check s.steps[1].items[3].len == 10 and s.way[1].path.len == 10
    check s.steps[0].items[3].len == 1 and s.way[0].count == 2

  test "a shown for another place, width, kind, mark, sibling or hidden doesn't hold":
    let t = hide(invoice)
    let s = t.shown([2, 1])              # 42, inside (amount 42)
    check s.part == some bl"42"
    let step = s.steps[1]                # (record 2 1 [SIB])
    let sib = t.parts[2].parts[0].digest
    check step == bl"(record 2 1 [$sib])"
    check s.way[1] == Step(kind: bRec, count: 2, index: 1, path: @[t.parts[2].parts[0].digest])
    let sibs = step.items[3]
    check not Shown.fromValue(s.withSteps(@[s.steps[0], bl"(record 2 0 $sibs)"])).holds
    check not Shown.fromValue(s.withSteps(@[s.steps[0], bl"(record 3 1 $sibs)"])).holds
    check not Shown.fromValue(s.withSteps(@[s.steps[0], bl"(list 2 1 $sibs)"])).holds
    check not Shown.fromValue(s.withSteps(@[s.steps[0], bl"!(record 2 1 $sibs)"])).holds
    let other = d(bl"other")
    check not Shown.fromValue(s.withSteps(@[s.steps[0], bl"(record 2 1 [$other])"])).holds
    check not Shown.fromValue(s.withSteps(@[s.steps[0]])).holds
    check not Shown.fromValue(s.withSteps(@[s.steps[1]])).holds
    check not Shown.fromValue(s.withSteps(@[s.steps[1], s.steps[0]])).holds
    # built in the host with a step that doesn't read, it holds nothing rather than refusing
    check not Shown(hidden: s.hidden, steps: @[bl"(record 4)"], node: s.node).holds
    check not Shown.fromValue(s.withNode(leaf(bl"43"))).holds
    let (steps, node) = (s.steps, s.node)
    check not Shown.fromValue(bl"(shown (hidden $other) $steps $node)").holds
    check Shown.fromValue(s.toValue).holds

  test "there is one value under a digest: a part shown alone and inside its parent agree":
    let t = hide(invoice)
    let alone = t.shown([2, 1])
    let parent = t.shown([2])
    check alone.holds and parent.holds
    # the parent's node is the root over its parts' nodes, which the inner
    # step rebuilds from the part: no other part fits there
    let f = frameOf(parent.node).get
    let inner = alone.way[1]
    check rebuiltFrom(nodeDigest(alone.node), inner.index, inner.count, inner.path) == some f.root.digest
    check rebuiltFrom(nodeDigest(leaf(bl"43")), inner.index, inner.count, inner.path) != some f.root.digest

  test "a shown that doesn't read is refused":
    let t = hide(invoice)
    let s = t.shown([1])
    refuses Shown.fromValue(s.withNode(bl"(node 1)"))
    refuses Shown.fromValue(s.withNode(bl"""(leaf 1 "salt")"""))
    refuses Shown.fromValue(s.withNode(bl"(leaf 1 0x00 more)"))
    refuses Shown.fromValue(s.withNode(bl"(record 3)"))
    let r = root(@[bl"1"])
    refuses Shown.fromValue(s.withNode(bl"(text $r)"))
    refuses Shown.fromValue(s.withSteps(@[bl"(record 4 4 [])"]))
    refuses Shown.fromValue(s.withSteps(@[bl"(record 4 -1 [])"]))
    refuses Shown.fromValue(s.withSteps(@[bl"(frame 4 1 [])"]))
    refuses Shown.fromValue(s.withSteps(@[bl"(record 4 1)"]))
    refuses Shown.fromValue(s.withSteps(@[bl"(record 4 1 {})"]))
    refuses Shown.fromValue(s.withSteps(@[readValue("(record 4! 1 [])")]))
    let (h, steps, node) = (s.hidden, s.steps, s.node)
    refuses Shown.fromValue(bl"(shown $h $steps $node more)")
    refuses Shown.fromValue(bl"!(shown $h $steps $node)")
    let one = d(bl"1")
    refuses Hidden.fromValue(bl"(hidden $one more)")

suite "salt":
  test "a salted leaf is blinded: two hidings differ, and the shown carries the salt":
    let (a, b) = (hide(invoice, salted = always), hide(invoice, salted = always))
    check a.digest != b.digest
    check a.digest != hide(invoice).digest
    let s = a.shown([1, 1])
    check s.holds and s.part == some toValue("alice")
    check s.node.items.len == 3 and s.node.items[2].kind == bBytes and s.node.items[2].bytes.len == SaltLen
    check Shown.fromValue(s.toValue).part == some toValue("alice")
    check not Shown.fromValue(s.withNode(leaf(toValue("alice")))).holds
    check not Shown.fromValue(s.withNode(leaf(toValue("alice"), bytes(newSeq[byte](SaltLen))))).holds

  test "a guessable neighbour's node can't be recomputed from a shown without its salt":
    let t = hide(invoice, salted = always)
    let s = t.shown([1, 0])              # `to`, beside "alice"
    let sib = s.way[1].path[0]
    check sib != nodeDigest(leaf(toValue("alice")))
    check sib == t.parts[1].parts[1].digest

suite "signing":
  test "a key signs (hidden D), and a stranger holding the signature takes the parts it is shown":
    let alice = seed(1)
    let t = hide(invoice, salted = always)
    let word = alice.signed(t.hidden.toValue).toValue
    # the stranger: the signed word, and two shown
    let o = opened(word)
    check o.isSome and o.get.signer == some alice.pubkey
    let h = Hidden.fromValue(o.get.said)
    let (head, to) = (Shown.fromValue(t.shown([0]).toValue), Shown.fromValue(t.shown([1, 1]).toValue))
    check head.hidden.digest == h.digest and to.hidden.digest == h.digest
    check head.part == some bl"invoice"
    check to.part == some toValue("alice")
    check Shown.fromValue(t.shown([1, 0]).toValue).part == some bl"to"
    check Shown.fromValue(t.shown([1]).toValue).part.isNone
    # the amount was never shown, and a shown against another word is no part of this one
    let other = hide(bl"""(invoice (to "alice") (amount 43) {sealed paid})""", salted = always)
    let forged = Shown.fromValue(other.shown([2]).toValue)
    check forged.holds and forged.hidden.digest != h.digest

  test "a range of a set inside a signed record is a shown and an opening under one signature":
    let alice = seed(2)
    let ledger = bl"""(ledger (acct "alice") {(invoice 1 40) (invoice 2 2) (paid 1) (note "x")})"""
    # everything apart but the set's members, which are whole and unsalted; the rest salted
    let t = hide(ledger, apart = v => v == ledger or v.isKind(bSet),
                 salted = v => not v.isKind(bRec))
    let word = alice.signed(t.hidden.toValue).toValue
    # alice shows the set as a frame node and opens everything under (invoice) in it
    let s = Shown.fromValue(t.shown([2]).toValue)
    let members = toSeq(ledger.items[2].members)
    let o = Opening.fromValue(opening(members, bl"(under (invoice))").toValue)
    # the stranger: the signature, the shown, the opening, nothing else
    let said = opened(word).get
    check said.signer == some alice.pubkey
    check s.hidden.digest == Hidden.fromValue(said.said).digest and s.holds
    let f = frameOf(s.node).get
    check f.kind == bSet and o.root.toValue == f.root.toValue
    check o.holds and o.members == @[bl"(invoice 1 40)", bl"(invoice 2 2)"]
    # the set's members had to be hidden whole and unsalted for that
    let salted = hide(ledger, apart = v => v == ledger or v.isKind(bSet),
                      salted = always)
    check frameOf(salted.parts[2].node).get.root.toValue != o.root.toValue

  test "a frame node shows a frame's kind, mark and width and nothing in it":
    let t = hide(invoice, salted = always)
    let s = Shown.fromValue(t.shown([3]).toValue)
    check s.holds and s.part.isNone
    let f = frameOf(s.node).get
    check f.kind == bSet and f.root.count.toInt == 2
    # and the set's members are then an opening away, against that root
    let members = toSeq(bl"{sealed paid}".members)
    check t.parts[3].runRoot == f.root.toValue
    check root(members).toValue != f.root.toValue    # salted: not the bare members' tree
    check t.parts[3].parts.mapIt(leafOf(it.node).get) == members
