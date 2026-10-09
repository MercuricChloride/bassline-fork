## find: queries written down as search spaces, and what they find

import std/[unittest, options, algorithm]
import bl/core
import bl/queries

template refuses(call: untyped) =
  expect ValueError:
    discard call

proc v(text: string): Value = readValue(text)
proc vs(texts: varargs[string]): seq[Value] =
  for t in texts: result.add v(t)

let repo = v"""!{!(kind search-space) (identity repo) (holds {
  ("a" dir) ("a" (has "a/x")) ("a" (has "a/y"))
  ("a/x" file) ("a/x" (about "the x file")) ("a/x" (in "a"))
  ("a/y" file) ("a/y" (about "the y file")) ("a/y" (in "a"))
  ((mentions x) "a/x") (help "ask a path") (odd !(within z))
})}"""

proc among(known: varargs[Value]): Search[Value, Value] =
  ## finds names among `known`, by their identities
  let ks = @known
  newSearch[Value, Value](proc(n: Value): Stream[Value] =
    initStream(ks).filter(proc(k: Value): bool = sharesIdentity(k, n)))

proc answers(q: Value, asked = none(Value), resolve: Search[Value, Value] = nil):
    seq[Value] =
  collect(rows(q, asked, resolve).map(proc(r: Row): Value = r.answer))

proc sorted(xs: seq[Value]): seq[Value] = xs.sorted(cmp)

suite "finds":
  test "answers what a space answers to a question":
    let q = find(subjects = [repo], holes = vs("a"), wheres = vs("(help a)"), gives = vs("a"))
    check answers(q) == vs("\"ask a path\"")

  test "feeds bindings from clause to clause, sharing holes":
    let q = find(subjects = [repo], holes = vs("p", "t"),
                 wheres = vs("((mentions x) p)", "(p (about t))"), gives = vs("(p t)"))
    check answers(q) == vs("(\"a/x\" \"the x file\")")

  test "gives the bindings when it says no gives":
    let q = find(subjects = [repo], holes = vs("p", "t"),
                 wheres = vs("((mentions x) p)", "(p (about t))"))
    check answers(q) == vs("{p: \"a/x\" t: \"the x file\"}")

  test "looks at every record for a clause whose question is not settled":
    let q = find(subjects = [repo], holes = vs("p"), wheres = vs("(p (in \"a\"))"), gives = vs("p"))
    check answers(q).sorted == vs("\"a/x\"", "\"a/y\"").sorted

  test "answers each binding once, written each way it gives":
    let q = find(subjects = [repo], holes = vs("p"), wheres = vs("((mentions x) p)"),
                 gives = vs("(path p)", "(seen p)"))
    check answers(q) == vs("(path \"a/x\")", "(seen \"a/x\")")

  test "distinct answers each answer once; a hole fits its own mark":
    let all = find(subjects = [repo], holes = vs("p", "x"), wheres = vs("(p x)"), gives = vs("kind"))
    check answers(all).len == 11  # (odd !(within z)) is passed over
    let once = find(subjects = [repo], holes = vs("p", "x"), wheres = vs("(p x)"),
                    gives = vs("kind"), kinds = [DistinctKind])
    check answers(once) == vs("kind")

  test "counts as it finds, never a total":
    let q = find(subjects = [repo], holes = vs("p"), wheres = vs("(p file)"), gives = vs("p"),
                 kinds = [CountKind])
    check answers(q) == vs("1", "2")

  test "says why: the parts whose records answered":
    let q = find(subjects = [repo], holes = vs("a"), wheres = vs("(help a)"), gives = vs("a"),
                 kinds = [WhyKind])
    check answers(q) == vs("(why \"ask a path\" {!{(identity repo)}})")
    let row = rows(find(subjects = [repo], holes = vs("a"), wheres = vs("(help a)")))().get
    check row.why == @[Because(clause: v("(help a)"), part: v("!{(identity repo)}"),
                               record: v("(help \"ask a path\")"))]

suite "forms":
  test "within fits anything with the part in it, the whole record bound by all":
    let q = find(subjects = [repo], holes = vs("r"), wheres = vs("!(all r !(within \"a/x\"))"),
                 gives = vs("r"))
    check answers(q).sorted == vs("(\"a\" (has \"a/x\"))", "(\"a/x\" file)",
      "(\"a/x\" (about \"the x file\"))", "(\"a/x\" (in \"a\"))",
      "((mentions x) \"a/x\")").sorted

  test "within inside a pattern looks deep, binding holes where it fits":
    let q = find(subjects = [repo], holes = vs("p"), wheres = vs("(p !(within \"a\"))"), gives = vs("p"))
    check answers(q).sorted == vs("\"a/x\"", "\"a/y\"").sorted
    let d = find(subjects = [repo], holes = vs("d"), wheres = vs("(\"a/x\" !(within (in d)))"),
                 gives = vs("d"))
    check answers(d) == vs("\"a\"")

  test "any fits what fits one of its parts":
    let q = find(subjects = [repo], holes = vs("p"), wheres = vs("(p !(any file dir))"), gives = vs("p"))
    check answers(q).sorted == vs("\"a\"", "\"a/x\"", "\"a/y\"").sorted

  test "as binds a hole to what fits, whatever its mark":
    let q = find(subjects = [repo], holes = vs("h", "a"), wheres = vs("(h !(as a))"),
                 gives = vs("a"), kinds = [DistinctKind])
    check v("!(within z)") in answers(q)
    let r = find(subjects = [repo], holes = vs("r"), wheres = vs("!(as r (help))"), gives = vs("r"))
    check answers(r) == vs("(help \"ask a path\")")
    proc bound(w: string): Value =
      find(subjects = [repo], holes = vs("p"), wheres = vs("((mentions x) !(as p))", w))
    check answers(bound("(p file)")) == vs("{p: \"a/x\"}")
    check answers(bound("(\"a/y\" !(as p))")).len == 0
    for w in ["!(as)", "!(as nothole)", "!(as h a b)"]:
      refuses Find.fromValue(find(subjects = [repo], holes = vs("h"), wheres = [v(w)]))

  test "quote is the value as written":
    let q = find(subjects = [repo], holes = vs("h"), wheres = vs("(h !(quote !(within z)))"),
                 gives = vs("h"))
    check answers(q) == vs("odd")

  test "a quoted question is settled, and asked as what it quotes":
    let base = v("!{!(kind search-space) (identity base) (holds {(q yes)})}")
    let inner = find(subjects = [base], holes = vs("a", "h"), asked = vs("h"),
                     wheres = vs("(h a)"), gives = vs("a"), id = v("inner"))
    check answers(find(subjects = [inner], holes = vs("a"), wheres = vs("(!(quote q) a)"),
                       gives = vs("a"))) == vs("yes")
    check answers(find(subjects = [inner], holes = vs("a", "h"), wheres = vs("(!(as h q) a)"),
                       gives = vs("[h a]"))) == vs("[q yes]")
    check answers(find(subjects = [inner], holes = vs("a", "h"), wheres = vs("(!(all h q) a)"),
                       gives = vs("[h a]"))) == vs("[q yes]")
    # a form fitting one record asks that record's question: !(as r) once r is bound
    let both = v("!{!(kind search-space) !(kind alt) (identity both2) (parts [" &
                 "!{!(kind search-space) (holds {(bind (q yes))})} " & $inner & "])}")
    check answers(find(subjects = [both], holes = vs("r"), wheres = vs("(bind r)", "!(as r)"),
                       gives = vs("r"))) == vs("(q yes)")
    # !(any …) asks each alternative's question, when each has one
    check answers(find(subjects = [inner], wheres = vs("!(any (q yes))"), gives = vs("ok"))) == vs("ok")
    check answers(find(subjects = [inner], holes = vs("a"), wheres = vs("!(any (q a) (nope a))"),
                       gives = vs("a"))) == vs("yes")
    # an alternative no record fits asks nothing, and needs no scan
    check answers(find(subjects = [inner], wheres = vs("!(any nope (q yes))"), gives = vs("ok"))) == vs("ok")
    # a head that is a form asks every head it can be
    check answers(find(subjects = [inner], wheres = vs("(!(any nope q) yes)"), gives = vs("ok"))) == vs("ok")
    check answers(find(subjects = [inner], wheres = vs("(!(any q) yes)"), gives = vs("ok"))) == vs("ok")

  test "a head that is a list or record fits any it begins, as in shapes; a set or dict any it covers":
    let s = v("""!{!(kind search-space) (identity s) (holds {
      ((tag extra) yes) ([tag extra] list) ({tag extra} set) ({k: 1 more: 2} dict) ((other) no)
    })}""")
    proc ask(head: string): seq[Value] =
      answers(find(subjects = [s], holes = vs("v"), wheres = [v("(" & head & " v)")], gives = vs("v")))
    check ask("(tag)") == vs("yes")
    check ask("[tag]") == vs("list")
    check ask("{tag}") == vs("set")
    check ask("{k: 1}") == vs("dict")
    # a bound hole or a quote is exactly one head
    check ask("!(quote (tag))").len == 0
    check answers(find(subjects = [s], holes = vs("h", "v"), asked = vs("h"), wheres = vs("(h v)"),
                       gives = vs("v")), some v("(tag)")).len == 0

  test "a scan of a ranked space comes in rank order, as do several questions of one":
    let s = v("!{!(kind search-space) !(kind ranked) (identity s) (holds {(a 9 aa) (b 0 bb)})}")
    check answers(find(subjects = [s], holes = vs("h", "x"), wheres = vs("(h x)"),
                       gives = vs("[h x]"))) == vs("[b bb]", "[a aa]")
    check answers(find(subjects = [s], holes = vs("x"), wheres = vs("!(any (a x) (b x))"),
                       gives = vs("x"))) == vs("bb", "aa")

  test "a hole under a quote is no hole, and counts for nothing in choosing a clause":
    let s = v("!{!(kind search-space) (identity s) (holds {(a [a1 z]) (a [a2 z]) (b b1) (b b2)})}")
    check answers(find(subjects = [s], holes = vs("x", "y", "z"),
                       wheres = vs("(a [y !(quote z)])", "(b x)"), gives = vs("[x y]"))) ==
      vs("[b1 a1]", "[b2 a1]", "[b1 a2]", "[b2 a2]")

  test "a hole is a hole, whatever is inside it":
    let t = v("!{!(kind search-space) (identity t) (holds {(q b) (r a)})}")
    check answers(find(subjects = [t], holes = vs("(q x)"), wheres = vs("(q x)"),
                       gives = vs("(q x)"))) == vs("(q b)", "(r a)")
    let s = v("!{!(kind search-space) (identity s) (holds {(q yes)})}")
    check answers(find(subjects = [s], holes = vs("{!(within)}"), wheres = vs("(q {!(within)})"),
                       gives = vs("{!(within)}"))) == vs("yes")
    # a hole, not within: marked, it fits only a marked record, and the space holds none
    check answers(find(subjects = [s], holes = vs("!(within q)"), wheres = vs("!(within q)"),
                       gives = vs("!(within q)"))).len == 0

  test "refuses a form without what it needs":
    for w in ["!(within)", "!(within a b)", "!(quote)", "!(any)", "!(all)"]:
      refuses Find.fromValue(find(subjects = [repo], wheres = [v(w)]))

suite "reading a find":
  test "refuses a kind it does not read, an asked that is no hole, count with why":
    refuses Find.fromValue(v("!{!(kind search-space) !(kind find) !(kind cat)}"))
    refuses Find.fromValue(v("!{!(kind search-space) !(kind find) (asked d)}"))
    refuses Find.fromValue(v("!{!(kind search-space) !(kind find) !(kind count) !(kind why)}"))
    refuses Find.fromValue(v("!{!(kind search-space) (holds {})}"))

  test "reads its parts back as written":
    let fd = Find.fromValue(v("!{!(kind search-space) !(kind find) !(kind distinct) (of s) (hole p) (asked p) (where (p x)) (gives p)}"))
    check fd.subjects == vs("s")
    check fd.holes == toBTreeSet(vs("p"))
    check fd.asked == vs("p")
    check fd.wheres == vs("(p x)")
    check fd.gives == vs("p")
    check (fd.once, fd.counting, fd.sayingWhy) == (true, false, false)

suite "subjects":
  let room = v"""!{!(kind search-space) !(kind ranked) (identity room) (holds {
    (general 1 !{!(kind message) (by bob) (said "yo")})
    (general 0 !{!(kind message) (by alice) (said "hi")})
    (general 2 !{!(kind message) (by alice) (said "again")})
  })}"""

  test "a ranked space answers in rank order, its rank passed over or bound":
    let q = find(subjects = [room], holes = vs("b", "s"),
                 wheres = vs("(general !{(by b) (said s)})"), gives = vs("(b s)"))
    check answers(q) == vs("(alice \"hi\")", "(bob \"yo\")", "(alice \"again\")")
    let r = find(subjects = [room], holes = vs("r"), wheres = vs("(general r !{(by bob)})"),
                 gives = vs("r"))
    check answers(r) == vs("1")

  test "an object answers its own records, and its orders":
    let note = v("!{!(kind note) (identity n1) (text \"hi\") (style quote)}")
    check answers(find(subjects = [note], holes = vs("t"), wheres = vs("(text t)"),
                       gives = vs("t"))) == vs("\"hi\"")
    check answers(find(subjects = [note], holes = vs("k"), wheres = vs("!(kind k)"),
                       gives = vs("k"))) == vs("note")
    # a record of another width is no answer
    let odd = v("!{!(kind note) (identity s) (q a b)}")
    check answers(find(subjects = [odd], holes = vs("x", "y"), wheres = vs("(q x y)"),
                       gives = vs("[x y]"))).len == 0

  test "a hole bound whatever its mark fits what it is bound to when met again":
    let s = v("!{!(kind search-space) (identity s) (holds {(a yes) (z yes)})}")
    check answers(find(subjects = [s], holes = vs("h!"), wheres = vs("(a !(as h!))", "(z h!)"),
                       gives = vs("h!"))) == vs("yes")

  test "names are found when asked, through what the asker hands in":
    let q = find(subjects = vs("repo"), holes = vs("a"), wheres = vs("(help a)"), gives = vs("a"))
    check answers(q, resolve = among(repo)) == vs("\"ask a path\"")
    refuses answers(q)

  test "a subject is read as fromValue reads a space, refusals passed over only when asked":
    proc ask(space: string, skipRefused = false): seq[Value] =
      collect(rows(find(subjects = [v(space)], holes = vs("x"), wheres = vs("(n x)"),
                        gives = vs("x")), skipRefused = skipRefused)
        .map(proc(r: Row): Value = r.answer))
    refuses ask("!{!(kind search-space) !(kind frob) (holds {(n 1)})}")
    refuses ask("!{!(kind search-space) !(kind cat) !(kind alt) (parts [])}")
    refuses ask("!{!(kind search-space) !(kind merge) (parts [])}")
    refuses ask("!{!(kind search-space) (holds [(n 1)])}")
    refuses ask("!{!(kind search-space) (holds {(n 1) (n 2 3)})}")
    check ask("!{!(kind search-space) (holds {(n 1) (n 2 3)})}", true) == vs("1")
    check ask("!{!(kind search-space) (holds {(n 1) (n)})}") == vs("1")
    # a composite's parts are ranked as it is, and are searches
    refuses ask("!{!(kind search-space) !(kind cat) (parts [!{!(kind search-space) !(kind ranked) (holds {(n 0 a)})}])}")
    refuses ask("!{!(kind search-space) !(kind cat) (parts [!{!(kind note) (n 1)}])}")
    check ask("!{!(kind search-space) !(kind ranked) !(kind merge) (parts [!{!(kind search-space) !(kind ranked) (holds {(n 0 a)})}])}") == vs("a")
    # a feed: each answer of the first asked of the second, ranked as the second
    check ask("!{!(kind search-space) !(kind feed) !(kind ranked) (parts [!{!(kind search-space) (holds {(n mid)})} !{!(kind search-space) !(kind ranked) (holds {(mid 0 a)})}])}") == vs("a")
    check ask("!{!(kind search-space) !(kind feed) (parts [!{!(kind search-space) (holds {(n mid)})} !{!(kind search-space) (holds {(mid a) (mid b)})}])}") == vs("a", "b")
    refuses ask("!{!(kind search-space) !(kind feed) (parts [!{!(kind search-space) (holds {(n mid)})}])}")
    # several lists of parts: each joined, and then the lists
    check ask("!{!(kind search-space) !(kind alt) (parts [!{!(kind search-space) (holds {(n a)})} !{!(kind search-space) (holds {(n b)})}]) (parts [!{!(kind search-space) (holds {(n c)})}])}") == vs("a", "c", "b")

  test "a rank is a natural of any size":
    let room = v("!{!(kind search-space) !(kind ranked) (identity room) (holds {(q 9223372036854775808 yes)})}")
    check answers(find(subjects = [room], holes = vs("x"), wheres = vs("(q x)"),
                       gives = vs("x"))) == vs("yes")

  test "a hole or form taking a ranked record takes it as held, rank and all":
    let room = v("!{!(kind search-space) !(kind ranked) (identity room) (holds {(general 0 \"hi\") (general 1 \"hi\") (q 7 yes)})}")
    check answers(find(subjects = [room], holes = vs("r"), wheres = vs("!(all r (general \"hi\"))"),
                       gives = vs("r"))) == vs("(general 0 \"hi\")", "(general 1 \"hi\")")
    check answers(find(subjects = [room], holes = vs("w"), wheres = vs("!(as w (q 7 yes))"),
                       gives = vs("w"))) == vs("(q 7 yes)")

  test "says why once for each set of parts that answers":
    let one = v("!{!(kind search-space) (identity one) (holds {(n 1)})}")
    let two = v("!{!(kind search-space) (identity two) (holds {(n 1)})}")
    let q = find(subjects = [one, two], holes = vs("x"), wheres = vs("(n x)"), gives = vs("x"),
                 kinds = [WhyKind])
    check answers(q).sorted == vs("(why 1 {!{(identity one)}})", "(why 1 {!{(identity two)}})").sorted

  test "says why for a clause that only checks, once for each part":
    let one = v("!{!(kind search-space) (identity one) (holds {(ready yes)})}")
    let two = v("!{!(kind search-space) (identity two) (holds {(ready yes)})}")
    let q = find(subjects = [one, two], wheres = vs("(ready yes)"), gives = vs("ok"),
                 kinds = [WhyKind])
    check answers(q).sorted == vs("(why ok {!{(identity one)}})", "(why ok {!{(identity two)}})").sorted

  test "what each binding leads to takes turns, so an endless subject starves none":
    let live = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      if q == v("n"): return initStream(vs("1", "2"))
      if q == v("2"): return just(v("two"))
      if q == v("1"):
        var i = 0
        return proc(): Option[Value] =
          inc i
          some initRec(@[v("more"), num(i)])
      empty Value)
    let q = find(holes = vs("x", "y"), wheres = vs("(n x)", "(x y)"), gives = vs("(x y)"))
    check v("(2 two)") in rows(q, subjects = @[asSubject(live)])
      .map(proc(r: Row): Value = r.answer).take(10)

  test "a gives is written only where the bindings bind every hole in it":
    let q = find(subjects = [repo], holes = vs("p", "f"), wheres = vs("(p !(any (has f) file))"),
                 gives = vs("(p f)"))
    check answers(q).sorted == vs("(\"a\" \"a/x\")", "(\"a\" \"a/y\")").sorted

  test "a search running here answers only what is settled":
    let live = newSearch[Value, Value](proc(q: Value): Stream[Value] =
      if q == v("views"): initStream(vs("table", "board")) else: empty Value)
    let q = find(holes = vs("x"), wheres = vs("(views x)"), gives = vs("x"))
    check collect(rows(q, subjects = @[asSubject(live)]).map(
      proc(r: Row): Value = r.answer)) == vs("table", "board")
    let open = find(holes = vs("x", "y"), wheres = vs("(x y)"), gives = vs("y"))
    check rows(open, subjects = @[asSubject(live)])().isNone

  test "several subjects take turns, and composites join their parts":
    let one = v("!{!(kind search-space) (identity one) (holds {(n 1) (n 2)})}")
    let two = v("!{!(kind search-space) (identity two) (holds {(n 10) (n 20)})}")
    proc q(subjects: seq[Value]): Value =
      find(subjects = subjects, holes = vs("x"), wheres = vs("(n x)"), gives = vs("x"))
    check answers(q(@[one, two])) == vs("1", "10", "2", "20")
    let both = v("!{!(kind search-space) !(kind cat) (identity both) (parts [one two])}")
    check answers(q(@[both]), resolve = among(one, two)) == vs("1", "2", "10", "20")

  test "names that lead round to themselves come to an end":
    let loop = v("!{!(kind search-space) !(kind cat) (identity loop) (parts [loop repo])}")
    let q = find(subjects = vs("loop"), holes = vs("a"), wheres = vs("(help a)"), gives = vs("a"))
    check answers(q, resolve = among(loop, repo)) == vs("\"ask a path\"")

  test "so do names that lead round through a find":
    let self = find(subjects = vs("loop2"), holes = vs("a"), wheres = vs("(help a)"),
                    gives = vs("a"), id = v("self"))
    let loop = v("!{!(kind search-space) !(kind alt) (identity loop2) (parts [self repo])}")
    check answers(self, resolve = among(self, loop, repo)) == vs("\"ask a path\"")
    check collect(Search[Value, Value].fromValue(self, resolve = among(self, loop, repo))
      .ask(null())) == vs("\"ask a path\"")

suite "a find as a search":
  let listing = find(subjects = vs("repo"), holes = vs("d", "f", "t"), asked = vs("d"),
                     wheres = vs("(d (has f))", "(f (about t))"), gives = vs("(f t)"),
                     id = v("listing"))

  test "binds what it is asked to its asked holes":
    check collect(findSearch(listing, among(repo)).ask(v("\"a\""))) ==
      vs("(\"a/x\" \"the x file\")", "(\"a/y\" \"the y file\")")

  test "reads back through fromValue, and composes like any space":
    let resolve = among(repo, listing)
    let s = Search[Value, Value].fromValue(listing, resolve = resolve)
    check collect(s.ask(v("\"a\""))) ==
      vs("(\"a/x\" \"the x file\")", "(\"a/y\" \"the y file\")")
    check s.toValue == listing
    let both = v("!{!(kind search-space) !(kind alt) (identity both) (parts [repo listing])}")
    check collect(Search[Value, Value].fromValue(both, resolve = resolve).ask(v("\"a\""))).sorted ==
      vs("dir", "(has \"a/x\")", "(has \"a/y\")", "(\"a/x\" \"the x file\")",
         "(\"a/y\" \"the y file\")").sorted

  test "is a subject another find asks":
    let q = find(subjects = [listing], holes = vs("e"), wheres = vs("(\"a\" e)"), gives = vs("e"))
    check answers(q, resolve = among(repo)) ==
      vs("(\"a/x\" \"the x file\")", "(\"a/y\" \"the y file\")")

  test "a find within a gives keeps its own holes whole, an outer hole inside one too":
    let s = v("!{!(kind search-space) (identity s) (holds {(r o)})}")
    let inner = v("!{!(kind search-space) !(kind find) (identity i) (hole [x]) (where ([x] v)) (gives [x])}")
    let q = find(subjects = [s], holes = vs("x"), wheres = vs("(r x)"), gives = [inner])
    check answers(q) == @[initSet(collect(inner.members) & initRec(@[OfQ, s]), true)]

  test "a gives can carry a find, its own holes kept and the subjects named":
    let inner = find(holes = vs("f"), wheres = vs("(d (has f))"), gives = vs("f"), id = v("inner"))
    let q = find(subjects = [repo], holes = vs("d"), wheres = vs("(d dir)"),
                 gives = [initDict(@[(v("dir"), v("d")), (v("files"), inner)])])
    let nested = answers(q)[0].dict[v("files")]
    check Find.fromValue(nested).wheres == vs("(\"a\" (has f))")
    check Find.fromValue(nested).subjects == @[repo]
    check collect(identities(nested)) == vs("[inner {d: \"a\"}]")
    # a name with a hole in it is filled, and still goes with every binding used
    let two = v("!{!(kind search-space) (identity two) (holds {(bind [same 1]) (bind [same 2])})}")
    let named = answers(find(subjects = [two], holes = vs("x", "y"), wheres = vs("(bind [x y])"),
      gives = vs("!{!(kind search-space) !(kind find) (identity x) (of nil) (where (q y))}")))
    check collect(initStream(named).flatMap(proc(a: Value): Stream[Value] = identities(a))).sorted ==
      vs("[same {x: same y: 1}]", "[same {x: same y: 2}]").sorted
    check answers(nested) == vs("\"a/x\"", "\"a/y\"")

suite "more: a search asked again of its answers":
  let tree = v("""!{!(kind search-space) (identity tree) (holds {
    (root (has a)) (a (has b)) (a (has b2)) (b (has c)) (c (has a))
  })}""")
  let down = find(subjects = vs("tree"), holes = vs("d", "f"), asked = vs("d"),
                  wheres = vs("(d (has f))"), gives = vs("f"), id = v("down"))
  let resolve = among(tree, down)

  test "nearest first, each once, and a walk that comes round again ends":
    let walk = v("!{!(kind search-space) !(kind more) (identity walk) (parts [down])}")
    let s = Search[Value, Value].fromValue(walk, resolve = resolve)
    check collect(s.ask(v("root"))) == vs("a", "b", "b2", "c")
    check s.toValue == walk

  test "via answers the way each answer was reached":
    let walk = v("!{!(kind search-space) !(kind more) !(kind via) (identity walk) (parts [down])}")
    check collect(Search[Value, Value].fromValue(walk, resolve = resolve).ask(v("root"))) ==
      vs("(via [root] a)", "(via [root a] b)", "(via [root a] b2)", "(via [root a b] c)")

  test "a step is any search, a find of two clauses among them":
    let board = v("""!{!(kind search-space) (identity board) (holds {
      (p1 (on top)) (p1 (shows inner)) (p2 (on inner)) (p2 (shows note))
    })}""")
    let inside = find(subjects = vs("board"), holes = vs("b", "p", "t"), asked = vs("b"),
                      wheres = vs("(p (on b))", "(p (shows t))"), gives = vs("t"),
                      id = v("inside"))
    let walk = v("!{!(kind search-space) !(kind more) (identity walk) (parts [inside])}")
    check collect(Search[Value, Value].fromValue(walk, resolve = among(board, inside))
      .ask(v("top"))) == vs("inner", "note")
    check collect(more(findSearch(inside, among(board))).ask(v("top"))) == vs("inner", "note")

  test "a more is a subject a find can ask":
    let walk = v("!{!(kind search-space) !(kind more) (identity walk) (parts [down])}")
    let q = find(subjects = [walk], holes = vs("x"), wheres = vs("(root x)"), gives = vs("x"))
    check answers(q, resolve = resolve) == vs("a", "b", "b2", "c")

  test "refuses via without more, and a more of other than one part":
    refuses Search[Value, Value].fromValue(
      v("!{!(kind search-space) !(kind cat) !(kind via) (parts [down])}"), resolve = resolve)
    refuses Search[Value, Value].fromValue(
      v("!{!(kind search-space) !(kind more) (parts [down down])}"), resolve = resolve)
