## the bl tools driven from outside: help, dispatch, cat and read, the pipe
## rule, local input, hash, search and eval

import cli

suite "help and usage":
  test "every tool's --help exits 0 with its usage on stdout":
    for cmd in ["bl --help", "bl -h", "bl cat --help", "bl read --help",
                "bl send --help", "bl serve --help", "bl reach --help",
                "bl hash --help", "bl search --help",
                "bl search under --help", "bl search walk --help", "bl search find --help",
                "bl eval --help",
                "bl which --help", "bl commands --help", "bl clave --help",
                "bl clave keygen --help", "bl clave sign --help",
                "bl clave verify --help"]:
      let r = sh(cmd)
      check r.code == 0
      check r.output.startsWith("usage: ")
      check r.errors == ""

  test "an unknown option is one line of reason, then the usage, exit 2":
    let r = sh("bl cat --nope")
    check r.code == 2
    check r.output == ""
    check r.errors.splitLines[0] == "-- bl cat: unknown option --nope"
    check "usage: bl cat" in r.errors

  test "bl alone is its usage, every command a line, exit 0":
    let r = sh("bl")
    check r.code == 0
    check r.output.startsWith("usage: bl NAME")   # the banner is for a terminal
    check '\e' notin r.output
    let lines = r.output.splitLines
    for name in ["cat", "search", "commands", "demo", "clave"]:
      check lines.anyIt(it.startsWith("  " & name & " "))
    check lines.allIt(it.runeLen <= 80)

  test "a wrong argument count, a flag given a value, a missing value":
    check sh("bl hash extra").code == 2
    check sh("bl reach").code == 2
    check sh("bl reach --sink=yes :1").code == 2
    check sh("bl cat --width").code == 2
    check sh("bl cat --width x").code == 2

  test "long options take a value three ways":
    let want = sh("bl cat --width 8", blb("[aaa bbb ccc]")).output
    check want.count('\n') > 1
    check sh("bl cat --width=8", blb("[aaa bbb ccc]")).output == want
    check sh("bl cat --width:8", blb("[aaa bbb ccc]")).output == want

suite "dispatch":
  test "a name bl doesn't have runs bl-NAME, arguments and status intact":
    let r = sh("bl demo a 'b c' --x")
    check r.output == "a|b c|--x|"
    check r.code == 3

  test "which says what would run":
    check sh("bl which cat").output == "builtin cat\n"
    check sh("bl which demo").output == fakes / "bl-demo" & "\n"
    # a bl-clave that can't execute is passed over, as a shell would
    check sh("bl which clave").output == bin / "bl-clave" & "\n"
    check sh("bl which nosuch").code == 1

  test "bl finds the tools beside it with them off PATH, as from an alias":
    let bl = "PATH=/usr/bin:/bin " & quoteShell(bin / "bl")
    check sh(bl & " which clave").output == bin / "bl-clave" & "\n"
    check sh(bl & " commands").output.splitLines.anyIt(it.startsWith("clave "))
    check sh(bl & " clave --help").code == 0

  test "an unknown command is a reason and the usage, exit 2":
    let r = sh("bl nosuch")
    check r.code == 2
    check "no command nosuch" in r.errors.splitLines[0]
    check "usage: bl NAME" in r.errors

  test "commands lists the builtins and what is on PATH":
    let r = sh("bl commands")
    check r.code == 0
    let lines = r.output.splitLines
    for name in ["cat", "read", "send", "serve", "reach", "hash", "search",
                 "which", "commands", "demo", "clave"]:
      check lines.anyIt(it.startsWith(name & " "))
    check not lines.anyIt(it.startsWith("search-demo")) # bl search lists it
    check bin notin r.output and fakes notin r.output   # names, not paths

suite "cat and read":
  test "bl cat then bl read reproduces the corpus byte for byte":
    check sh("bl cat " & quoteShell(corpusPath) & " | bl read").output ==
      corpus
    check sh("bl cat | bl read", corpus).output == corpus
    check sh("bl cat --width 24 - | bl read -", corpus).output == corpus

  test "cat writes one value per line":
    let r = sh("bl cat", blb("1 (a b) {k: v} go!"))
    check r.output == "1\n(a b)\n{k: v}\ngo!\n"

  test "read takes files in turn":
    let a = file("a.bl", "(a 1)")
    let b = file("b.bl", "(b 2) [3]")
    check sh("bl read " & a & " " & b).output == blb("(a 1) (b 2) [3]")

  test "read emits a value before its input closes":
    let p = startProcess(bin / "bl", args = ["read"], options = {})
    p.inputStream.write("(a b)\n")
    p.inputStream.flush()
    check readFor(cint(p.outputHandle), 6, ms = 3000) == blb("(a b)")
    p.inputStream.close()
    check p.waitForExit == 0
    p.close

suite "the pipe rule":
  test "empty input is silence and exit 0":
    let key = tmp / "empty-key.blb"
    check sh("bl clave keygen --out " & key).code == 0
    for cmd in ["bl cat", "bl read", "bl hash", "bl search walk",
                "bl search under '(a)'", "bl send", "bl send :1",
                "bl clave sign --key " & key, "bl clave verify"]:
      let r = sh(cmd)
      check r == ("", "", 0)

  test "input that ends partway through a value: said on stderr, exit 1":
    let cut = blb("[b c]")[0 .. ^2]
    for cmd in ["bl cat", "bl hash", "bl search walk", "bl send :1",
                "bl clave verify"]:
      let r = sh(cmd, cut)
      check r.code == 1
      check "stdin ends partway through a value" in r.errors
    let r = sh("bl read", "(a 1) [b c")
    check r.code == 1
    check r.output == blb("(a 1)")
    check "ends partway through a value" in r.errors

  test "the values before a cut still go out":
    let r = sh("bl cat", blb("(a 1) [b c]")[0 .. ^2])
    check r.output == "(a 1)\n"

  test "malformed input: the reason on stderr, exit 1":
    for cmd in ["bl cat", "bl hash", "bl search walk"]:
      let r = sh(cmd, "\x00")
      check r.code == 1
      check "stdin is not CE: invalid tag" in r.errors
    check sh("bl read", "(a ))").code == 1

  test "a closed downstream pipe ends a tool quietly with exit 0":
    let big = file("big.blb", blb("(a b c) ".repeat(100_000)))
    let bigText = file("big.bl", "(a b c) ".repeat(100_000))
    for cmd in ["bl cat " & big, "bl read " & bigText, "bl hash < " & big,
                "bl search walk < " & big]:
      let r = sh("(" & cmd & "; echo $? > " & tmp / "status" & ") | head -c 1")
      check r.output.len == 1
      check r.errors == ""
      check readFile(tmp / "status").strip == "0"

suite "local input":
  test "a value past a listener's cap still goes through a local filter":
    let size = 110 * 1024 * 1024
    var ce = "\x57\xff"
    for shift in [24, 16, 8, 0]:
      ce.add char((size shr shift) and 0xff)
    let big = file("huge.blb", ce & '\0'.repeat(size))
    let r = sh("bl hash < " & big)
    check r.code == 0
    check r.output.decoded.len == 1

suite "hash":
  test "each value to (digest ALGO 0x…) over its CE":
    let vs = readDocument("\"x\" (a b) 42!")
    var want: string
    for v in vs:
      want.add digest(v, Sha256Algo).toValue.ce.toString
    check sh("bl hash", blb("\"x\" (a b) 42!")).output == want
    check sh("bl hash --algo blake2b", blb("\"x\"")).output.decoded ==
      @[digest(vs[0], Blake2bAlgo).toValue]
    check sh("bl hash --algo md5").code == 2

suite "search":
  let known = blb("(person alice) (person bob 3) (personal x) [person] " &
                  "(person) !(person mallory) (place home)")

  test "under answers every value the prefix selects":
    let r = sh("bl search under '(person)'", known)
    check r.code == 0
    check r.output == blb("(person alice) (person bob 3) (person)")
    check sh("bl search under '!(person)'", known).output ==
      blb("!(person mallory)")
    check sh("bl search under '(person alice)'", known).output ==
      blb("(person alice)")

  test "an inline query is the textual syntax before it is CE":
    # 10 is also the CE of the text "0", and Bob of the symbol ob
    let nums = blb("10 \"0\" Bob ob")
    check sh("bl search under 10", nums).output == blb("10")
    check sh("bl search under Bob", nums).output == blb("Bob")
    check sh("bl search under 1000", blb("1000 1")).output == blb("1000")

  test "find answers a find, its names found among the values on stdin":
    let people = "!{!(kind search-space) (identity people) " &
                 "(holds {(alice (age 30)) (bob (age 41)) (alice (likes tea))})}"
    let r = sh("bl search find '!{!(kind search-space) !(kind find) " &
               "(of people) (hole p) (hole a) (where (p (age a))) " &
               "(gives (p a))}'", blb(people))
    check r.code == 0
    check r.output == blb("(bob 41) (alice 30)")  # CE order: shortlex
    # with no (of …), every object on stdin and a space of the other records
    check sh("bl search find '!{!(kind search-space) !(kind find) (hole p) " &
             "(where (person p)) (gives p)}'", known).output == blb("alice")
    # each answer once, as values arrive
    check sh("bl search find '!{!(kind search-space) !(kind find) !(kind count) " &
             "(hole p) (where (person p)) (gives p)}'",
             known & blb("(person carol)")).output == blb("1 2")
    check sh("bl search find nope", known).code == 2
    # distinct holds across arrivals
    check sh("bl search find '!{!(kind search-space) !(kind find) !(kind distinct) " &
             "(hole x) (hole n) (where (x n)) (gives n)}'", blb("(b 1) (a 1)")).output ==
      blb("1")
    # a space it can't read is said on stderr, exit 1
    let r2 = sh("bl search find '!{!(kind search-space) !(kind find) (of odd) (hole n) " &
                "(where (n x)) (gives n)}'",
                blb("!{!(kind search-space) !(kind frob) (identity odd) (holds {})}"))
    check r2.code == 1
    check "a kind this doesn't read" in r2.errors

  test "a query is read by recognition: a file, CE or text":
    let asText = file("q.bl", "(person)")
    let asCE = file("q.blb", blb("(person)"))
    let want = sh("bl search under '(person)'", known).output
    check sh("bl search under " & asText, known).output == want
    check sh("bl search under " & asCE, known).output == want
    check sh("bl search under '(a' ", known).code == 2
    check sh("bl search under", known).code == 2

  test "walk answers each subvalue, depth first, the value itself first":
    let r = sh("bl search walk", blb("(a [b c] {k: v}) 1"))
    check r.output == blb("(a [b c] {k: v}) a [b c] b c {k: v} k v 1")

  test "-n takes that many answers and stops":
    check sh("bl search under '(person)' -n 2", known).output ==
      blb("(person alice) (person bob 3)")
    check sh("bl search under -n1 '(person)'", known).output ==
      blb("(person alice)")
    check sh("bl search walk -n 0", known) == ("", "", 0)
    # it stops reading too: nothing after the answers it took is judged
    check sh("bl search walk -n 1", blb("1") & "\x00").code == 0

  test "alone, it lists the searches here, a line each":
    let r = sh("bl search")
    check r.code == 0
    let lines = r.output.splitLines
    check lines.anyIt(it.startsWith("under PREFIX "))
    check lines.anyIt(it.startsWith("walk "))
    check lines.anyIt(it.startsWith("demo ") and
                      "says hello whatever it is asked" in it)
    check bin notin r.output and fakes notin r.output   # names, not paths

  test "a search bl doesn't have runs bl-search-NAME":
    check sh("bl search demo anything").output == "hello"
    check sh("bl search nosuch").code == 2

suite "eval":
  test "does each value, writing what it answers":
    let r = sh("bl eval -q", blb("!(add !(mul 2 3) 4) (inert !(add 1 2)) " &
                                 "!(all [!(in [1 2 3])]) !(nope)"))
    check r.code == 0
    check r.output == blb("10 (inert !(add 1 2)) [1 2 3]")

  test "says on stderr what nothing does, and passes a refused branch over":
    let r = sh("bl eval 2>&1 >/dev/null", blb("!(nope) !(div 12 !(in [1 0 2]))"))
    check "nothing here does !(nope)" in r.output
    check "passed over: div by zero" in r.output

  test "does rules given with --with before the vocabulary":
    let rules = file("fib.bl", "(rule (shape !(fib n) {n}) " &
      "[!(if [!(lt n! 2)] [n!] [!(add !(fib !(sub n! 1)) !(fib !(sub n! 2)))])])")
    let half = file("half.bl", "[(rule (shape !(add a b) {a b}) [mine])]")
    check sh("bl eval -q --with " & rules, blb("!(fib 15)")).output == blb("610")
    check sh("bl eval -q --with " & half, blb("!(add 1 2)")).output == blb("mine")

  test "a refusal nothing else answers ends the run":
    let r = sh("bl eval -q", blb("!(div 1 0) 2"))
    check r.code != 0
