## evidence: roots, proofs of inclusion and growth, checkpoints,
## equivocation and receipts, each a value that carries its own check

import std/[algorithm, options, sequtils, unittest]
import bl/[core, queries]
import bl/lib/[blah, jam, evidence]
import bl/lib/crypto/[clave, digest]

proc seed(n: byte): Keypair =
  var s: Seed
  for i in 0 ..< 32: s[i] = n
  keypairFromSeed(s)

proc d(v: Value): Value = digest(v, Blake2bAlgo).toValue

proc leaves(n: int): seq[Value] =
  for i in 0 ..< n: result.add d(toValue(i))

proc inRec(r: Root, i: int, leaf: Value, path: seq[Value]): Value =
  bl"(in $r $i $leaf $path)"

proc growsRec(older, newer: Root, path: seq[Value]): Value =
  bl"(grows $older $newer $path)"

template refuses(call: untyped) =
  expect MoldError:
    discard call

suite "roots":
  test "a root is a count and a digest, read exactly":
    let r = root(leaves(3))
    check r.count.toInt == 3
    let dg = r.digest
    check r.toValue == bl"(root 3 $dg)"
    check Root.fromValue(r.toValue).digest == r.digest
    refuses Root.fromValue(bl"(root -1 $dg)")
    refuses Root.fromValue(bl"(root 3 $dg more)")

  test "the tree is made of values, so a leaf can't pass as a node":
    let a = leaves(1)[0]
    check rootDigest([a]) == d(bl"(leaf $a)")
    let (l, r) = (rootDigest([a]), rootDigest([leaves(2)[1]]))
    check rootDigest(leaves(2)) == d(bl"(node $l $r)")
    check rootDigest([]) == d(bl"(node)")
    check rootDigest([]) != rootDigest([bl"(node)"])

  test "a root splits at the greatest power of two below its count":
    let ls = leaves(5)
    let (l, r) = (rootDigest(ls[0 .. 3]), rootDigest(ls[4 .. 4]))
    check rootDigest(ls) == d(bl"(node $l $r)")
    let (ll, lr) = (rootDigest(ls[0 .. 1]), rootDigest(ls[2 .. 3]))
    check rootDigest(ls[0 .. 3]) == d(bl"(node $ll $lr)")

  test "leaves may be anything, marked too: a set's members commit to the set":
    let s = randValue(2)
    let members = toSeq(s.members)
    if members.len > 0:
      let p = inclusion(members, members.high)
      check p.holds and p.leaf == members[^1]
      check Inclusion.fromValue(p.toValue).holds
    let marked = @[readValue("go!"), bl"1", readValue("!(do it)")]
    for i in 0 .. 2:
      let p = inclusion(marked, i)
      check p.holds and p.leaf == marked[i]
      check Inclusion.fromValue(p.toValue).holds

suite "inclusion":
  test "every leaf of every small tree has a proof that holds":
    for n in 1 .. 33:
      let ls = leaves(n)
      for i in 0 ..< n:
        let p = inclusion(ls, i)
        check p.holds
        check p.root.toValue == root(ls).toValue
        check Inclusion.fromValue(p.toValue).holds

  test "a proof's path is logarithmic in the leaves":
    check inclusion(leaves(1), 0).path.len == 0
    check inclusion(leaves(2), 1).path.len == 1
    check inclusion(leaves(1024), 511).path.len == 10
    check inclusion(leaves(1025), 1024).path.len == 1

  test "a proof for another leaf, place, root or path doesn't hold":
    let ls = leaves(7)
    let p = inclusion(ls, 3)
    var q = p.toValue
    check not Inclusion.fromValue(inRec(p.root, 4, p.leaf, p.path)).holds
    check not Inclusion.fromValue(inRec(p.root, 3, ls[4], p.path)).holds
    check not Inclusion.fromValue(inRec(root(leaves(8)), 3, p.leaf, p.path)).holds
    check not Inclusion.fromValue(inRec(p.root, 3, p.leaf, p.path[0 .. 1])).holds
    var swapped = p.path
    swap(swapped[0], swapped[1])
    check not Inclusion.fromValue(inRec(p.root, 3, p.leaf, swapped)).holds
    check Inclusion.fromValue(q).holds

  test "a place outside the leaves is refused on reading":
    let p = inclusion(leaves(3), 1)
    refuses Inclusion.fromValue(inRec(p.root, 3, p.leaf, p.path))
    refuses Inclusion.fromValue(inRec(p.root, -1, p.leaf, p.path))

  test "an inner node given as a leaf doesn't hold: the shape is fixed by the count":
    let ls = leaves(4)
    let inner = rootDigest(ls[0 .. 1])       # the digest of (node l0 l1)
    # a path one shorter, from where the inner node sits
    let forged = inRec(root(ls), 0, inner, @[rootDigest(ls[2 .. 3])])
    check not Inclusion.fromValue(forged).holds

suite "growth":
  test "every prefix of every small tree grows into it":
    for n in 0 .. 33:
      let ls = leaves(n)
      for m in 0 .. n:
        let g = growth(ls, m)
        check g.holds
        check Growth.fromValue(g.toValue).holds

  test "a growth proof is logarithmic too":
    check growth(leaves(1024), 512).path.len == 1
    check growth(leaves(1025), 1024).path.len == 1
    check growth(leaves(1000), 333).path.len <= 20

  test "a tree that isn't a prefix doesn't grow into another":
    let ls = leaves(9)
    var other = ls
    other[2] = d(bl"other")
    let g = growth(ls, 5)
    check not Growth.fromValue(growsRec(root(other[0 .. 4]), g.newer, g.path)).holds
    check not Growth.fromValue(growsRec(g.older, root(other), g.path)).holds
    check not Growth.fromValue(growsRec(g.older, g.newer, g.path[0 .. ^2])).holds
    check not Growth.fromValue(growsRec(root(ls[0 .. 5]), g.newer, g.path)).holds
    check not Growth.fromValue(growsRec(g.newer, g.older, g.path)).holds

  test "a root of no leaves is one digest, so nothing grows from a fake nothing":
    let bad = initRec(@[sym"root", bl"0", d(toValue("not nothing"))])
    refuses Root.fromValue(bad)
    refuses Growth.fromValue(initRec(@[sym"grows", bad, root(leaves(3)).toValue, initList(newSeq[Value]())]))
    refuses Growth.fromValue(initRec(@[sym"grows", root([]).toValue, bad, initList(newSeq[Value]())]))
    check Growth.fromValue(growsRec(root([]), root([]), @[])).holds

  test "anything grows from nothing, and a tree grows into itself with no path":
    check Growth.fromValue(growsRec(root([]), root(leaves(5)), @[])).holds
    check Growth.fromValue(growsRec(root(leaves(5)), root(leaves(5)), @[])).holds
    check not Growth.fromValue(growsRec(root(leaves(5)), root(leaves(6)), @[])).holds

suite "checkpoints and receipts":
  let kp = seed(5)
  let alice = Speaker(name: sym"alice", key: some seed(9))
  let sq = bl"(stamps jam)"

  proc told(): (Jam, ref seq[Value]) =
    ## a stamping jam, and everything it told a line that hears which
    ## jam it is, general, and its stamps
    let jam = newJam(spaceVar[Value, Ranked[Value]](), key = some kp)
    let heardAll = new seq[Value]
    let line = jam.newLine(v => (block:
      heardAll[].add v
      true))
    for q in [jamQ, bl"general", sq, bl"(checkpoints general)"]: discard jam.hear(line, initRec(@[q]))
    for s in ["one", "two", "three", "four", "five"]:
      discard jam.hear(line, bl"(general $s)")
    (jam, heardAll)

  test "a checkpoint is a root over what a reader heard, over the jam that told it; another reader agrees":
    let (_, all) = told()
    let (a, b) = (spaceVar[Value, Ranked[Value]](), spaceVar[Value, Ranked[Value]]())
    for v in all[]: discard a.keep(v)
    for v in all[].reversed: discard b.keep(v)
    let (ca, cb) = (a.checkpoint(bl"general", 4), b.checkpoint(bl"general", 4))
    check ca.root.count.toInt == 3 and ca.toValue == cb.toValue
    check ca.over == jamOf(a).get
    check ca.over.isObject and ca.over.answers(identityQ).exists(n => n == bl"jam")
    let later = a.checkpoint(bl"general", 100)
    check later.root.count.toInt == 5
    check growth(a.leaves(bl"general", 100), 3).older.digest == ca.root.digest

  test "a reader told by no jam, or by two, has no one order to checkpoint over":
    let local = spaceVar[Value, Ranked[Value]]()
    discard local.keep(bl"""(general 1 "hi")""")
    refuses local.checkpoint(bl"general", 1)
    let (_, a) = told()
    let (_, b) = told()
    let mixed = spaceVar[Value, Ranked[Value]]()
    for v in a[]: discard mixed.keep(v)
    for v in b[]: discard mixed.keep(v)
    check toSeq(mixed[jamQ]).len == 2
    refuses mixed.checkpoint(bl"general", 100)

  test "a checkpoint put signed where checkpoints go is read back as one; one answer is proved against it":
    let (jam, all) = told()
    let local = spaceVar[Value, Ranked[Value]]()
    for v in all[]: discard local.keep(v)
    let c = local.checkpoint(bl"general", 100)
    let line = jam.newLine(proc(v: Value): bool =
      all[].add v
      true)
    check jam.hear(line, alice.put(checkpointsQ(bl"general"), c.toValue))
    let found = toSeq(local.heardIn(checkpointsQ(bl"general")))   # nothing yet: not kept
    check found.len == 0
    for v in all[]: discard local.keep(v)
    let cps = toSeq(local.heardIn(checkpointsQ(bl"general")).filterMap(checkpointOf))
    check cps.len == 1 and cps[0].toValue == c.toValue
    # a third party holding only the checkpoint and one message checks it
    let said = toSeq(local.heardIn(bl"general"))
    let p = inclusion(local.leaves(bl"general", 100), 2)
    check p.holds and p.leaf == said[2].digestOf and p.root.toValue == cps[0].root.toValue
    # an unsigned checkpoint, one put elsewhere, or one that doesn't read, isn't one
    check jam.hear(line, bl"(general $c)")
    check jam.hear(line, initRec(@[checkpointsQ(bl"general"), c.toValue]))
    let (over, r) = (c.over, c.root)
    check jam.hear(line, alice.put(checkpointsQ(bl"general"), bl"(checkpoint $over general -1 $r)"))
    for v in all[]: discard local.keep(v)
    check toSeq(local.heardIn(bl"general").filterMap(checkpointOf)).len == 0
    check toSeq(local.heardIn(checkpointsQ(bl"general")).filterMap(checkpointOf)).len == 1

  test "a receipt is an answer as told with the stamp that vouches for it":
    let (_, all) = told()
    let local = spaceVar[Value, Ranked[Value]]()
    for v in all[]: discard local.keep(v)
    let said = toSeq(local.heardIn(bl"general"))
    let stamped = toSeq(local.heardIn(sq))
    let s = stamped.filterIt(it.rank == said[1].rank)[0]
    let r = receipt(said[1], s)
    check r.vouchedBy == some kp.pubkey
    check Receipt.fromValue(r.toValue).vouchedBy == some kp.pubkey
    let wrong = receipt(said[2], s)
    check wrong.vouchedBy.isNone
    let resigned = receipt(said[1], Heard(answer: seed(6).signed(s.said).toValue))
    check resigned.vouchedBy == some seed(6).pubkey   # another key's word, as that key's

suite "equivocation":
  let kp = seed(5)
  let sq = bl"(stamps jam)"

  proc teaMsg(rank: int, d, prev: Value, at = 0): Value =
    TeaMsg(ordinal: rank, at: at, prev: prev, value: bl"(general $d)").toValue
  proc stamp(kp: Keypair, rank: int, d, prev: Value): Value =
    kp.signed(teaMsg(rank, d, prev)).toValue
  let (x, y) = (d(toValue("x")), d(toValue("y")))

  test "a slot is what a key speaks for once":
    let s = kp.stamp(3, x, null())
    check slot(opened(s).get.said, kp.pubkey) == some initRec(@[slotHead, kp.pubkey.toValue, null(), bl"3"])
    let over = identity(bl"jam", bl"1")
    let r = root(leaves(3))
    let c = bl"(checkpoint $over general 7 $r)"
    check slot(initRec(@[checkpointsQ(bl"general"), c]), kp.pubkey) == some bl"(slot $over (checkpoints general) 7)"
    check slot(bl"(general $c)", kp.pubkey).isNone          # put elsewhere
    check slot(teaMsg(-3, x, null()), kp.pubkey).isNone

  test "two stamps by one key for one rank that differ convict it":
    let (a, b) = (kp.stamp(3, x, null()), kp.stamp(3, y, null()))
    check equivocation(a, b).convicts == some kp.pubkey
    check Equivocation.fromValue(equivocation(a, b).toValue).convicts == some kp.pubkey
    check equivocation(a, a).convicts.isNone                         # one word
    check equivocation(a, kp.stamp(4, y, null())).convicts.isNone   # another rank
    check equivocation(a, seed(6).stamp(3, y, null())).convicts.isNone   # another key
    let restamped = kp.signed(teaMsg(3, x, null(), at = 1)).toValue
    check equivocation(a, restamped).convicts == some kp.pubkey      # a new clock is a new word

  test "two checkpoints by one key for one rank over one order that differ convict it; over two orders they are two words":
    let alice = seed(9)
    let (ra, rb) = (root(leaves(3)), root(leaves(4)))
    let (one, two) = (identity(bl"jam", bl"1"), identity(bl"jam", bl"2"))
    proc cp(over: Value, r: Root, q = bl"general"): Value =
      alice.signed(initRec(@[checkpointsQ(bl"general"), bl"(checkpoint $over $q 7 $r)"])).toValue
    check equivocation(cp(one, ra), cp(one, rb)).convicts == some alice.pubkey
    check equivocation(cp(one, ra), cp(two, rb)).convicts.isNone     # another jam, another slot
    let elsewhere = alice.signed(bl"(general (checkpoint $one general 7 $rb))").toValue
    check equivocation(cp(one, ra), elsewhere).convicts.isNone       # not put where checkpoints go
    let unread = alice.signed(initRec(@[checkpointsQ(bl"general"), bl"(checkpoint $one general -7 $rb)"])).toValue
    check equivocation(cp(one, ra), unread).convicts.isNone          # not a checkpoint at all

  test "what isn't signed, or doesn't hold, is no evidence":
    let a = kp.stamp(3, x, null())
    let bare = teaMsg(3, y, null())
    check equivocation(a, bare).convicts.isNone
    var torn = a
    torn = initRec(@[torn.items[0], bare, torn.items[2]])
    check equivocation(a, torn).convicts.isNone

suite "openings":
  proc sorted(vs: varargs[Value]): seq[Value] =
    ## members in CE order, each once, as a set holds them
    toSeq(initSet(@vs).members)

  proc nums(n: int): seq[Value] =
    for i in 0 ..< n: result.add toValue(i * 2)   # 0 2 4 …, with gaps to ask about

  test "an opening shows exactly the members in a range, checked against brute force":
    # a universe in CE order, which for integers is not numeric order;
    # the set is every other member of it, so there are gaps to ask about
    for n in 0 .. 20:
      var all: seq[Value]
      for i in 0 .. 2 * n + 1: all.add toValue(i)
      let universe = sorted(all)
      var ms: seq[Value]
      for i in 0 ..< universe.len:
        if i mod 2 == 1: ms.add universe[i]
      for lo in 0 ..< universe.len:
        for hi in lo ..< universe.len:
          let r = fromTo(universe[lo], universe[hi])
          let o = opening(ms, r)
          check o.holds
          check Opening.fromValue(o.toValue).holds
          check o.members == ms.filterIt(cmp(it, universe[lo]) >= 0 and cmp(it, universe[hi]) <= 0)

  test "a span's proof is about two paths' worth of siblings however wide the span":
    let ms = nums(1024)
    check opening(ms, fromTo(bl"100", bl"1900")).path.len <= 20
    check opening(ms, fromTo(bl"100", bl"1900")).members.len == 901
    check opening(ms, fromTo(bl"0", bl"2046")).path.len == 0       # the whole set
    check opening(ms, fromTo(bl"500", bl"500")).path.len <= 20
    check opening(ms, fromTo(bl"500", bl"500")).span.len == 3     # 498 500 502

  test "(under P) opens everything under a head, which CE keeps contiguous":
    let ms = sorted(bl"(invoice 1)", bl"(invoice 2 paid)", bl"(invoice)", bl"(order 1)", bl"7",
                    toValue("invoice"), bl"invoice", bl"(invoice 2)", bl"(receipt 1)", readValue("!(invoice 3)"))
    let o = opening(ms, under(bl"(invoice)"))
    check o.holds
    check o.members == sorted(bl"(invoice 1)", bl"(invoice 2 paid)", bl"(invoice)", bl"(invoice 2)")
    for m in o.members: check prefixes(bl"(invoice)", m)
    let marked = opening(ms, under(readValue("!(invoice)")))
    check marked.holds and marked.members == @[readValue("!(invoice 3)")]
    check opening(ms, under(bl"(shipment)")).holds
    check opening(ms, under(bl"(shipment)")).members.len == 0
    check opening(ms, under(bl"invoice")).members == @[bl"invoice"]     # a symbol prefixes itself alone

  test "an opening with nothing in its range is a proof of absence":
    let ms = nums(9)                            # 0 2 4 … 16
    let o = opening(ms, fromTo(bl"5", bl"5"))
    check o.holds and o.members.len == 0
    check o.absent(bl"5")
    check not o.absent(bl"6")          # not in the range asked
    let wide = opening(ms, fromTo(bl"3", bl"9"))
    check wide.members == @[bl"4", bl"6", bl"8"]
    check wide.absent(bl"5") and wide.absent(bl"7") and not wide.absent(bl"4") and not wide.absent(bl"10")
    check opening(@[], fromTo(bl"1", bl"2")).absent(bl"1")

  test "a member hidden, a span moved, a bracket faked or an order broken doesn't hold":
    let ms = nums(16)
    let o = opening(ms, fromTo(bl"6", bl"12"))     # span 4 6 8 10 12 14 at index 2
    check o.index.toInt == 2 and o.span.len == 6
    proc re(index: int, span: seq[Value], path = o.path, root = o.root): Opening =
      Opening.fromValue(initRec(@[sym"opening", root.toValue, o.range, toValue(index), initList(span), initList(path)]))
    check not re(2, o.span[0 .. 3] & o.span[5 .. 5]).holds        # 10 hidden
    check not re(3, o.span).holds                                  # moved
    check not re(2, @[bl"4", bl"6", bl"8", bl"10", bl"12", bl"13"]).holds   # bracket not above 12: root fails anyway
    check not re(2, @[bl"4", bl"8", bl"6", bl"10", bl"12", bl"14"]).holds   # order
    var short = o.path[0 .. ^2]
    check not re(2, o.span, short).holds
    check not re(2, o.span, o.path, root(nums(15))).holds
    # a span whose brackets don't bracket: a correct tree, wrong range claimed
    let claims = Opening.fromValue(initRec(@[sym"opening", o.root.toValue, fromTo(bl"0", bl"12"), bl"2", initList(o.span), initList(o.path)]))
    check not claims.holds                                        # 4 is not below 0, and 2 is hidden
    refuses Opening.fromValue(initRec(@[sym"opening", o.root.toValue, o.range, bl"12", initList(o.span), initList(o.path)]))
    refuses Opening.fromValue(initRec(@[sym"opening", o.root.toValue, fromTo(bl"9", bl"1"), bl"2", initList(o.span), initList(o.path)]))

  test "two openings of one range show its whole change, and sometimes that nothing else moved":
    let before = nums(10)                       # 0 2 … 18
    var replaced = before
    replaced[3] = bl"7"                          # 6 becomes 7: same count, same shape
    let r = fromTo(bl"4", bl"10")
    let c = changed(opening(before, r), opening(replaced, r))
    check c.holds and Changed.fromValue(c.toValue).holds
    check c.scope == (added: @[bl"7"], removed: @[bl"6"])
    check c.unchangedOutside
    let grown = sorted(before & @[bl"5", bl"100"])    # an insertion reshapes the tree
    let g = changed(opening(before, r), opening(grown, r))
    check g.holds and g.scope == (added: @[bl"5"], removed: newSeq[Value]())
    check not g.unchangedOutside
    var elsewhere = before
    elsewhere[8] = bl"17"                        # 16 becomes 17, outside the range
    let e = changed(opening(before, r), opening(elsewhere, r))
    check e.holds and e.scope == (added: newSeq[Value](), removed: newSeq[Value]())
    check not e.unchangedOutside
    check not changed(opening(before, r), opening(replaced, fromTo(bl"4", bl"12"))).holds   # two ranges
