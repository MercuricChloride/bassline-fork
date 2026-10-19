## claims: evidence composed into one value a reader checks; what
## evidence entails, premises nobody fills but the reader, convictions

import std/[algorithm, options, sequtils, unittest]
import bl/[core, queries]
import bl/lib/[jam, evidence, hidden, claims]
import bl/lib/crypto/[clave, digest]

proc seed(n: byte): Keypair =
  var s: Seed
  for i in 0 ..< 32: s[i] = n
  keypairFromSeed(s)

proc d(v: Value): Value = digest(v, Blake2bAlgo).toValue
proc key(kp: Keypair): Value = kp.pubkey.toValue
proc v(text: string): Value = readValue(text)
proc vs(texts: varargs[string]): seq[Value] =
  for t in texts: result.add v(t)

proc leaves(n: int): seq[Value] =
  for i in 0 ..< n: result.add d(toValue(i))

let reading = entailments()
proc entailed(x: Value): seq[Value] = toSeq(reading[x]).sorted(cmp)
proc answers(xs: Stream[Conviction]): seq[Value] = toSeq(xs).mapIt(it.answer).sorted(cmp)

template refuses(call: untyped) =
  expect MoldError:
    discard call

let anything = find(holes = vs("q", "a"), wheres = vs("(q a)"))

suite "what evidence entails":
  test "a proof of inclusion that holds entails its leaf's place; one that doesn't, nothing":
    let ls = leaves(5)
    let p = inclusion(ls, 3)
    check entailed(p.toValue) == @[v("((in " & $root(ls).toValue & " 3) " & $ls[3] & ")")]
    let forged = initRec(@[sym"in", p.root.toValue, bl"2", p.leaf, initList(p.path)])
    check entailed(forged).len == 0

  test "growth entails the newer root from the older":
    let ls = leaves(6)
    let g = growth(ls, 4)
    check entailed(g.toValue) == @[v("((grew " & $g.older.toValue & ") " & $g.newer.toValue & ")")]

  test "an opening entails what it shows in its range, and a changed its scope as shown":
    let members = sorted(@[bl"1", bl"2", bl"3", v"(invoice 1)", v"(invoice 2)", v"zed"], cmp)
    let o = opening(members, under(v"(invoice)"))
    let root = root(members).toValue
    check entailed(o.toValue) == sorted(@[
      v("((member " & $root & " (under (invoice))) (invoice 1))"),
      v("((member " & $root & " (under (invoice))) (invoice 2))"),
      v("((opened " & $root & " (under (invoice))) {(invoice 1) (invoice 2)})")], cmp)
    var later = members
    later[later.find(v"(invoice 1)")] = v"(invoice 3)"
    later.sort(cmp)
    let ch = changed(o, opening(later, under(v"(invoice)")))
    let newer = evidence.root(later).toValue
    check entailed(ch.toValue) == sorted(@[
      v("((scope " & $root & " " & $newer & " (under (invoice))) {added: {(invoice 3)} removed: {(invoice 1)}})"),
      v("((added " & $root & " " & $newer & " (under (invoice))) (invoice 3))"),
      v("((removed " & $root & " " & $newer & " (under (invoice))) (invoice 1))"),
      v("((unchanged-outside " & $root & " " & $newer & ") (under (invoice)))")], cmp)

  test "a signature entails what its key signed, as a put when it is one, and what that entails":
    let alice = seed(1)
    let p = inclusion(leaves(3), 1)
    let put = initRec(@[v"proofs", p.toValue])
    let s = alice.signed(put).toValue
    check entailed(s) == sorted(@[
      statement(v("(signed " & $alice.key & ")"), put),
      statement(v("(put " & $alice.key & " proofs)"), p.toValue),
      entailed(p.toValue)[0]], cmp)
    let torn = initRec(@[v"signed", initRec(@[v"proofs", bl"7"]), s.items[2]])
    check entailed(torn).len == 0

  test "a bare statement handed in as evidence entails nothing; neither does what reads as no evidence":
    check entailed(v"((signed 0x01) anything)").len == 0
    check entailed(v"((pinned alice) 0x01)").len == 0
    check entailed(v"(checkpoint x y 3 (root 0 0x00))").len == 0

  test "bytes entail what they read as, once, and what that entails; malformed or several, nothing":
    let p = inclusion(leaves(4), 2)
    let raw = bytes(ce(p.toValue))
    check entailed(raw) == sorted(@[statement(v("(reads " & $raw & ")"), p.toValue), entailed(p.toValue)[0]], cmp)
    check entailed(bytes(ce(p.toValue) & ce(bl"1"))).len == 0
    check entailed(bytes(ce(p.toValue)[0 .. ^2])).len == 0
    check entailed(bytes(@[0xffu8, 0xff, 0xff])).len == 0
    check entailed(readValue("0x00!")).len == 0

  test "a receipt entails what the jam stamped; an equivocation whom it convicts":
    let kp = seed(5)
    let jam = newJam(spaceVar[Value, Ranked[Value]](), key = some kp)
    let all = new seq[Value]
    let line = jam.newLine(x => (block:
      all[].add x
      true))
    for q in [bl"general", bl"(stamps jam)"]: discard jam.hear(line, initRec(@[q]))
    discard jam.hear(line, bl"""(general "one")""")
    let local = spaceVar[Value, Ranked[Value]]()
    for x in all[]: discard local.keep(x)
    let said = toSeq(local.heardIn(bl"general"))[0]
    let stamped = toSeq(local.heardIn(bl"(stamps jam)")).filterIt(it.rank == said.rank)[0]
    let r = receipt(said, stamped)
    check entailed(r.toValue) == @[statement(v("(stamped " & $kp.key & ")"), r.told)]
    let resigned = receipt(said, Heard(answer: seed(6).signed(stamped.said).toValue))
    check entailed(resigned.toValue) == @[statement(v("(stamped " & $seed(6).key & ")"), resigned.told)]
    let sq = bl"(stamps jam)"
    proc stamp(rank: int, dg: Value): Value =
      kp.signed(TeaMsg(ordinal: rank, at: 0, prev: null(), value: bl"(general $dg)").toValue).toValue
    let e = equivocation(stamp(3, d(toValue("x"))), stamp(3, d(toValue("y"))))
    check entailed(e.toValue) == @[statement(v("(convicted " & $kp.key & ")"),
                                             initRec(@[slotHead, kp.pubkey.toValue, null(), bl"3"]))]
    check entailed(equivocation(stamp(3, d(toValue("x"))), stamp(4, d(toValue("y")))).toValue).len == 0

  test "readings compose: a reader's own reading is asked of nested evidence too":
    let alice = seed(1)
    proc mine(x: Value, again: Entails): Stream[Value] =
      ## a reader that reads (vouch NAME WHEN) as a statement, and nothing else
      matchValue x:
      of "(vouch $name $_)": just(statement(v"vouched", name))
      else: empty Value
    let both = entailments([Reading(entails), Reading(mine)])
    let s = alice.signed(v"(vouch bob today)").toValue
    check toSeq(both[s]).sorted(cmp) == sorted(@[
      statement(v("(signed " & $alice.key & ")"), v"(vouch bob today)"), statement(v"vouched", v"bob")], cmp)
    check toSeq(reading[s]) == @[statement(v("(signed " & $alice.key & ")"), v"(vouch bob today)")]
    check toSeq(entailments([Reading(mine)])[s]).len == 0   # mine alone opens no signature

suite "claims":
  test "a claim is a find and evidence, read exactly; its find names no subjects and counts nothing":
    let c = claim(anything, [inclusion(leaves(2), 0).toValue])
    check Claim.fromValue(c.toValue).asks == anything
    check c.find.holes.len == 2
    refuses Claim.fromValue(v"(claim nope {})")
    refuses claim(find(subjects = [v"!{(identity x)}"], holes = vs("q", "a"), wheres = vs("(q a)")), [])
    refuses claim(find(holes = vs("q", "a"), wheres = vs("(q a)"), kinds = [countKind]), [])
    refuses Claim.fromValue(initRec(@[v"claim", anything, initSet(@[]), bl"1"]))

  test "a claim within a claim lends its evidence":
    let inner = claim(anything, [inclusion(leaves(2), 0).toValue])
    let outer = claim(anything, [inner.toValue])
    check toSeq(outer.statements) == toSeq(inner.statements)

  test "digests are answered on demand for any settled value, one per algorithm":
    let c = claim(find(holes = vs("dg"), wheres = vs("((digest-of (a 1)) dg)"), gives = vs("dg")), [])
    check c.convinced(given()).answers ==
      sorted(@[digest(v"(a 1)", Blake2bAlgo).toValue, digest(v"(a 1)", Sha256Algo).toValue], cmp)
    let open = claim(find(holes = vs("x", "dg"), wheres = vs("((digest-of x) dg)"), gives = vs("x")), [])
    check toSeq(open.convinced(given())).len == 0   # nothing settled, nothing asked

suite "being convinced":
  let kp = seed(5)
  let (alice, bob, carol) = (seed(9), seed(10), seed(11))

  proc told(): (Jam, ref seq[Value]) =
    let jam = newJam(spaceVar[Value, Ranked[Value]](), key = some kp)
    let heardAll = new seq[Value]
    let line = jam.newLine(x => (block:
      heardAll[].add x
      true))
    for q in [jamQ, bl"general", bl"(stamps jam)"]: discard jam.hear(line, initRec(@[q]))
    for s in ["one", "two", "three", "four", "five"]: discard jam.hear(line, bl"(general $s)")
    (jam, heardAll)

  proc reader(all: seq[Value]): BVar[Value, Ranked[Value]] =
    result = spaceVar[Value, Ranked[Value]]()
    for x in all: discard result.keep(x)

  proc signedCheckpoint(kp: Keypair, c: Checkpoint): Value =
    kp.signed(initRec(@[checkpointsQ(bl"general"), c.toValue])).toValue

  proc checkpointClause(over: Value, rank: int, root = "root"): string =
    "((put k (checkpoints general)) (checkpoint !(quote " & $over & ") general " & $rank & " " & root & "))"

  test "convinced only where evidence and premises meet, and says which records it leaned on":
    let (_, all) = told()
    let (a, b) = (reader(all[]), reader(all[].reversed))
    let (ca, cb) = (a.checkpoint(bl"general", 4), b.checkpoint(bl"general", 4))
    let said = toSeq(a.heardIn(bl"general"))
    let p = inclusion(a.leaves(bl"general", 4), 2)
    check p.leaf == said[2].digestOf
    let asks = find(holes = vs("who", "k", "root", "i", "over"),
      wheres = vs("((in root i) !(quote " & $p.leaf & "))",
                  "((put k (checkpoints general)) (checkpoint !(as over) general 4 root))",
                  "((pinned who) k)", "(order !(as over))"),
      gives = vs("(agrees who root)"))
    let c = claim(asks, [p.toValue, alice.signedCheckpoint(ca), bob.signedCheckpoint(cb)])
    let mine = given(statement(v"(pinned alice)", alice.key), statement(v"(pinned bob)", bob.key),
                     statement(v"order", ca.over))
    let got = toSeq(c.convinced(mine))
    check got.mapIt(it.answer).sorted(cmp) ==
      vs("(agrees alice " & $ca.root.toValue & ")", "(agrees bob " & $ca.root.toValue & ")").sorted(cmp)
    for x in got:
      check x.given.len == 2 and x.entailed.len == 2
      check statement(v"order", ca.over) in x.given
      check statement(v"(pinned alice)", alice.key) in x.given or statement(v"(pinned bob)", bob.key) in x.given
      # the records as held: the leaf's place, and the signed put the key made
      check statement(v("(in " & $ca.root.toValue & " 2)"), p.leaf) in x.entailed
      check x.entailed.anyIt(it.items[0].head == putHead)
    # read back as written
    let written = got[0].toValue
    check Conviction.fromValue(written).toValue == written
    # the checker as a search, asked the claim written down
    let answers = toSeq(convincing(mine)[c.toValue])
    check answers.len == 2 and answers[0] == got[0].toValue
    check toSeq(convincing(mine)[bl"1"]).len == 0

  test "nothing in a claim fills a premise":
    let (_, all) = told()
    let a = reader(all[])
    let ca = a.checkpoint(bl"general", 4)
    let asks = find(holes = vs("who", "k", "root"),
      wheres = vs(checkpointClause(ca.over, 4), "((pinned who) k)"), gives = vs("who"))
    let forged = statement(v"(pinned carol)", carol.key)
    let c = claim(asks, [carol.signedCheckpoint(ca), forged])
    check toSeq(c.convinced(given())).len == 0
    check toSeq(c.convinced(given(statement(v"(pinned alice)", alice.key)))).len == 0
    check c.convinced(given(forged)).answers == vs("carol")

  test "the reader's own hearing is a premise, and is rested on as held, rank and all":
    let (_, all) = told()
    let a = reader(all[])
    let ca = a.checkpoint(bl"general", 4)
    let heard = claim(find(holes = vs("r", "m", "k", "root"),
      wheres = vs("(general r m)", checkpointClause(ca.over, 4)),
      gives = vs("(heard m root)")), [carol.signedCheckpoint(ca)])
    let rows = toSeq(heard.convinced(a.search.toValue))
    check rows.len == 5
    for x in rows:
      check x.given.len == 1 and x.given[0].items.len == 3 and x.given[0].head == bl"general"
      check x.entailed.len == 1

  test "a statement both entailed and given convinces twice, once resting on each":
    let s = alice.signed(v"(vouch bob)").toValue
    let c = claim(find(holes = vs("k", "w"), wheres = vs("((signed k) (vouch w))"), gives = vs("w")),
                  [s])
    let mine = given(statement(v("(signed " & $alice.key & ")"), v"(vouch bob)"))
    let got = toSeq(c.convinced(mine))
    check got.mapIt(it.answer) == vs("bob", "bob")
    check got.mapIt(it.entailed.len).sorted == @[0, 1] and got.mapIt(it.given.len).sorted == @[0, 1]
    check toSeq(c.convinced(given())).len == 1

  test "two readers whose checkpoints differ are convinced of different roots, and growth joins them":
    let (_, all) = told()
    let a = reader(all[])
    let (c4, c5) = (a.checkpoint(bl"general", 4), a.checkpoint(bl"general", 100))
    let g = growth(a.leaves(bl"general", 100), 3)
    check g.older.toValue == c4.root.toValue and g.newer.toValue == c5.root.toValue
    let asks = find(holes = vs("k", "r1", "r2"),
      wheres = vs(checkpointClause(c4.over, 4, "r1"), checkpointClause(c5.over, 100, "r2"),
                  "((grew r1) r2)", "(pinned k)"),
      gives = vs("(grew r1 r2)"))
    let c = claim(asks, [alice.signedCheckpoint(c4), alice.signedCheckpoint(c5), g.toValue])
    let got = toSeq(c.convinced(given(statement(v"pinned", alice.key))))
    check got.mapIt(it.answer) == @[initRec(@[sym"grew", c4.root.toValue, c5.root.toValue])]
    check got[0].entailed.len == 3 and got[0].given.len == 1

suite "a shown as evidence":
  test "a shown that holds entails its part at its place, or its frame node as it is; one that doesn't, nothing":
    let invoice = bl"""(invoice (to "alice") (amount 42) {sealed paid})"""
    let t = hide(invoice, apart = x => x == invoice or x.isKind(bSet),
                 salted = x => not x.isKind(bSym))
    let hidden = t.hidden.toValue
    let shownTo = t.shown([1]).toValue
    check entailed(shownTo) == @[statement(v("(part " & $hidden & " [(record 4 1)])"), bl"""(to "alice")""")]
    let shownSet = t.shown([3])
    check entailed(shownSet.toValue) == @[statement(v("(frame " & $hidden & " [(record 4 3)])"), shownSet.node)]
    let other = initRec(@[v"shown", hidden, shownSet.steps[0 .. 0].initList, leaf(toValue("alice"))])
    check entailed(other).len == 0

  test "a claim joins a signature over (hidden D) with a shown and an opening under it":
    let alice = seed(1)
    let ledger = bl"""(ledger (acct "alice") {(invoice 1 40) (invoice 2 2) (paid 1) (note "x")})"""
    let t = hide(ledger, apart = x => x == ledger or x.isKind(bSet),
                 salted = x => not x.isKind(bRec))
    let word = alice.signed(t.hidden.toValue).toValue
    let members = toSeq(ledger.items[2].members)
    let c = claim(find(holes = vs("k", "h", "who", "r", "m"), wheres = vs(
                    "((pinned alice) k)",
                    "((signed k) (hidden h))",
                    "((part (hidden h) [(record 3 1)]) who)",
                    "((frame (hidden h) [(record 3 2)]) (set r))",
                    "((member r (under (invoice))) m)"),
                  gives = vs("(invoiced who m)")),
                  [word, t.shown([1]).toValue, t.shown([2]).toValue,
                   opening(members, under(v"(invoice)")).toValue])
    let mine = given(statement(v"(pinned alice)", alice.key))
    check c.convinced(mine).answers ==
      sorted(@[v("(invoiced (acct \"alice\") (invoice 1 40))"), v("(invoiced (acct \"alice\") (invoice 2 2))")], cmp)
    let one = toSeq(c.convinced(mine))[0]
    check one.given.len == 1 and one.entailed.len == 4
    check toSeq(c.convinced(given(statement(v"(pinned alice)", seed(2).key)))).len == 0
