## the bl toolkit, driven from outside: the built binaries in ../bin,
## run through a shell or as live child processes, against the shared
## corpus and against fakes placed first on PATH

import std/[algorithm, json, net, options, os, osproc, posix, sequtils, streams, strtabs, strutils, unittest]
import bl/core
from bl/queries import answer, knownAs
import bl/lib/crypto/digest
from bl/lib/jam import heard, vouched
from bl/lib/crypto/clave import Keypair, fromValue
from std/unicode import runeLen

let
  here = currentSourcePath().parentDir
  bin = here.parentDir / "bin"
  corpusPath = here.parentDir.parentDir.parentDir / "corpus" / "corpus.blb"
  corpus = readFile(corpusPath)
  corpusCount = block:
    var n = 0
    for _ in ValueView.decode(corpus.toOpenArrayByte(0, corpus.high)): inc n
    n
  tmp = getTempDir() / ("blcli-" & $getpid())
  fakes = tmp / "fakes"

doAssert fileExists(bin / "bl") and fileExists(bin / "bl-clave") and
  fileExists(bin / "bl-jam"),
  "build first: nim build"
createDir(fakes)
putEnv("PATH", fakes & ":" & bin & ":" & getEnv("PATH"))

proc fake(name, script: string, executable = true) =
  writeFile(fakes / name, "#!/bin/sh\n" & script & "\n")
  if executable:
    setFilePermissions(fakes / name, {fpUserRead, fpUserWrite, fpUserExec})

fake "bl-demo", """for a in "$@"; do printf '%s|' "$a"; done; exit 3"""
fake "bl-search-demo", """
case "$1" in --help) echo "says hello whatever it is asked"; exit 0 ;; esac
printf 'hello'"""
fake "bl-clave", "echo not me", executable = false
fake "ssh", """
# stands in for ssh: drops its options and the host, and runs the rest
# through a shell here, as the far side's shell would
while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
[ "$1" = unreachable ] && exit 255
shift
exec sh -c "$*"
"""

type Ran = tuple[output, errors: string, code: int]

var runs = 0
proc sh(cmd: string, input = ""): Ran =
  ## `cmd` through sh, `input` on its stdin
  inc runs
  let base = tmp / ("run" & $runs)
  writeFile(base & ".in", input)
  let code = execCmd("(" & cmd & ") < " & quoteShell(base & ".in") & " > " &
                     quoteShell(base & ".out") & " 2> " &
                     quoteShell(base & ".err"))
  (readFile(base & ".out"), readFile(base & ".err"), code)

proc blb(text: string): string =
  ## the CE of the values `text` spells
  for v in readDocument(text):
    result.add v.ce.toString

proc text(ce: string): seq[Value] =
  for v in Value.decode(ce.toOpenArrayByte(0, ce.high)):
    result.add v

proc file(name, content: string): string =
  result = tmp / name
  writeFile(result, content)

proc readFor(fd: cint, want: int, ms = 5000): string =
  ## up to `want` bytes from `fd`, waiting at most `ms` for each piece
  var buf = newString(65536)
  while result.len < want:
    var p = TPollfd(fd: fd, events: POLLIN)
    if poll(addr p, 1, cint(ms)) <= 0:
      break
    let n = posix.read(fd, addr buf[0], min(buf.len, want - result.len))
    if n <= 0:
      break
    result.add buf[0 ..< n]

# ================ a listener running alongside ================

type Serving = object
  p: Process
  place: string

proc serve(place: string, extra: seq[string] = @[]): Serving =
  ## `bl serve PLACE`, once it says where it listens
  result.p = startProcess(bin / "bl", args = @["serve", place] & extra,
                          options = {})
  let said = result.p.errorStream.readLine
  doAssert said.startsWith("-- listening on "), said
  result.place = said["-- listening on ".len .. ^1]

proc port(s: Serving): string =
  s.place[s.place.rfind(':') + 1 .. ^1]

proc arrived(s: Serving, want: int): string =
  ## what it has written of the values that arrived, up to `want` bytes
  readFor(cint(s.p.outputHandle), want)

proc stop(s: Serving): string =
  ## its chatter, once it has gone
  discard kill(Pid(s.p.processID), SIGTERM)
  discard s.p.waitForExit
  result = s.p.errorStream.readAll
  s.p.close

# ================ a place that speaks ================

type Peer = object
  server: Socket
  port: int

proc peer(): Peer =
  result.server = newSocket(buffered = false)
  result.server.setSockOpt(OptReuseAddr, true)
  result.server.bindAddr(Port(0), "127.0.0.1")
  result.server.listen()
  result.port = int(result.server.getLocalAddr()[1])

proc talk(p: Peer, says: string): string =
  ## takes one connection, says `says` and ends its speaking, then hears
  ## until the other side ends
  var c: Socket
  p.server.accept(c)
  if says.len > 0:
    c.send(says)
  discard shutdown(c.getFd, SHUT_WR)
  while true:
    let got = c.recv(65536)
    if got.len == 0: break
    result.add got
  c.close()
  p.server.close()

proc chattyPeer(ratio: int): tuple[port: int, pid: Pid] =
  ## a place, in a child process, that answers each piece it hears
  ## `ratio` times over with blocking writes, until the other side ends
  let p = peer()
  result.port = p.port
  result.pid = fork()
  if result.pid == 0:
    var c: Socket
    p.server.accept(c)
    let fd = cint(c.getFd)
    var buf = newString(65536)
    while true:
      let n = posix.read(fd, addr buf[0], buf.len)
      if n <= 0: break
      for _ in 1 .. ratio:
        var done = 0
        while done < n:
          let w = posix.write(fd, addr buf[done], n - done)
          if w <= 0: exitnow(1)
          done += w
    discard shutdown(c.getFd, SHUT_WR)
    exitnow(0)
  p.server.close()

# ================================================================

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
    check r.output.text.len == 1

suite "hash":
  test "each value to (digest ALGO 0x…) over its CE":
    let vs = readDocument("\"x\" (a b) 42!")
    var want: string
    for v in vs:
      want.add digest(v, Sha256Algo).toValue.ce.toString
    check sh("bl hash", blb("\"x\" (a b) 42!")).output == want
    check sh("bl hash --algo blake2b", blb("\"x\"")).output.text ==
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

suite "send and serve":
  test "send into serve over TCP delivers every value byte for byte":
    let s = serve(":0")
    let r = sh("bl send " & s.place, corpus)
    check r.code == 0
    check r.errors == "-- sent " & $corpusCount & " value(s) to " & s.place & "\n"
    check s.arrived(corpus.len) == corpus
    let chatter = s.stop
    check "-- open 127.0.0.1:" in chatter
    check "-- close 127.0.0.1:" in chatter

  test "send reaches serve by every TCP spelling, one connection each":
    let s = serve("127.0.0.1:0")
    var want: string
    for (spelled, host, said) in [("tcp://127.0.0.1:", "127.0.0.1", "(tcp)"),
                                  ("127.0.0.1:", "127.0.0.1", "(hostport)"),
                                  ("localhost:", "localhost", "(named)"),
                                  (":", "127.0.0.1", "(colon)"),
                                  ("", "127.0.0.1", "(bare)")]:
      let r = sh("bl send " & spelled & s.port, blb(said))
      check r.code == 0
      check r.errors == "-- sent 1 value(s) to " & host & ":" & s.port & "\n"
      want.add blb(said)
    check s.arrived(want.len) == want
    check s.stop.count("-- open ") == 5

  test "with no place, send and serve meet at 127.0.0.1:8455":
    let p = startProcess(bin / "bl", args = ["serve"], options = {})
    let said = p.errorStream.readLine
    if said != "-- listening on 127.0.0.1:8455":
      skip()
      discard kill(Pid(p.processID), SIGTERM)
    else:
      check sh("bl send", blb("(hello)")).code == 0
      check readFor(cint(p.outputHandle), 8) == blb("(hello)")
      # ssh://host alone reaches the far side's default place
      let r = sh("bl send ssh://far", blb("(far)"))
      check r.code == 0
      check r.errors == "-- sent 1 value(s) to ssh://far/127.0.0.1:8455\n"
      check readFor(cint(p.outputHandle), 6) == blb("(far)")
      discard kill(Pid(p.processID), SIGTERM)
    discard p.waitForExit
    p.close

  test "serve says when the other end stops partway through a value":
    let s = serve(":0")
    check sh("bl reach --source " & s.place, blb("(a b)")[0 .. ^2]).code == 0
    check sh("bl reach --source " & s.place, "\x00").code == 0
    check sh("bl send " & s.place, blb("(after)")).code == 0
    check s.arrived(blb("(after)").len) == blb("(after)")
    let chatter = s.stop
    check "-- truncated 127.0.0.1:" in chatter
    check "-- malformed 127.0.0.1:" in chatter

  test "--max-value drops a connection that sends something bigger":
    let s = serve(":0", @["--max-value", "16"])
    check sh("bl send " & s.place, blb("\"" & "x".repeat(40) & "\"")).code == 0
    check sh("bl send " & s.place, blb("small")).code == 0
    check s.arrived(blb("small").len) == blb("small")
    check "past --max-value 16" in s.stop

  test "send over ssh:// runs bl reach on the far side":
    let s = serve(":0")
    let r = sh("bl send ssh://far/:" & s.port, corpus)
    check r.code == 0
    check r.errors == "-- sent " & $corpusCount & " value(s) to ssh://far/" &
                      s.place & "\n"
    check s.arrived(corpus.len) == corpus
    discard s.stop

  test "an unreachable place, or no place at all":
    let p = peer()
    p.server.close() # nothing listens there now
    let r = sh("bl send :" & $p.port, blb("1"))
    check r.code == 1
    check "can't reach 127.0.0.1:" & $p.port in r.errors
    check sh("bl reach :" & $p.port).code == 1
    check sh("bl send nowhere", blb("1")).code == 2
    check sh("bl send 70000", blb("1")).code == 2
    check sh("bl send ::1:80", blb("1")).code == 2
    check sh("bl send ssh://", blb("1")).code == 2
    check sh("bl send ssh://far/", blb("1")).code == 2
    check sh("bl send ssh://far/0", blb("1")).code == 2
    check sh("bl send ssh://-oProxyCommand=x/:1", blb("1")).code == 2
    let serving = sh("bl serve ssh://far/:1")
    check serving.code == 2
    check "a listener is local" in serving.errors.splitLines[0]

  test "a unix socket or any other path is refused, exit 2":
    for place in ["unix:" & tmp / "s.sock", tmp / "s.sock", "./s.sock",
                  "../s.sock", "socks/s.sock", "ssh://far" & tmp / "s.sock",
                  "ssh://far/" & tmp / "s.sock"]:
      for cmd in ["bl send ", "bl serve ", "bl reach ",
                  "bl reach --source "]:
        let r = sh(cmd & quoteShell(place), blb("1"))
        check r.code == 2
        check r.output == ""
        check r.errors.splitLines[0].endsWith(
          "not a place: " & place & " (" &
          (if place.startsWith("ssh://"): "on the far side, " else: "") &
          "unix sockets aren't places, only TCP)")

suite "reach":
  test "duplex: stdin into the place, the place onto stdout":
    let p = peer()
    let r = startProcess(bin / "bl", args = ["reach", ":" & $p.port],
                         options = {})
    r.inputStream.write(blb("(to place)"))
    r.inputStream.close()
    check p.talk(blb("(from place)")) == blb("(to place)")
    check r.outputStream.readAll == blb("(from place)")
    check r.waitForExit == 0
    r.close

  test "-- CMD puts the place on a command's stdin and stdout":
    let p = peer()
    let r = startProcess(bin / "bl", args = ["reach", "127.0.0.1:" & $p.port,
                                             "--", "hash"], options = {})
    check p.talk(blb("\"x\"")).text ==
      @[digest(text(blb("\"x\""))[0], Sha256Algo).toValue]
    check r.waitForExit == 0
    r.close

  test "--sink only hears":
    let p = peer()
    let r = startProcess(bin / "bl", args = ["reach", "--sink",
                                             "tcp://127.0.0.1:" & $p.port],
                         options = {})
    r.inputStream.write("never sent")
    r.inputStream.close()
    check p.talk(blb("(heard)")) == ""
    check r.outputStream.readAll == blb("(heard)")
    check r.waitForExit == 0
    r.close

  test "a place that speaks more than it hears doesn't wedge the pump":
    let (port, pid) = chattyPeer(8)
    let input = file("chatty.in", "x".repeat(2 * 1024 * 1024))
    let r = startProcess("/bin/sh", args = ["-c", "exec " & bin / "bl" &
                         " reach :" & $port & " < " & input], options = {})
    let heard = readFor(cint(r.outputHandle), 16 * 1024 * 1024)
    check heard.len == 16 * 1024 * 1024
    if heard.len < 16 * 1024 * 1024:
      r.kill()
      discard kill(pid, SIGKILL)
    check r.waitForExit == 0
    r.close
    var status: cint
    discard waitpid(pid, status, 0)

  test "over ssh:// with a command, a failed ssh is a failure":
    let r = sh("bl reach --source ssh://unreachable -- read", "(one)")
    check r.code == 1
    check "ended with status 255" in r.errors

  test "over ssh://, alone and with a command":
    let s = serve(":0")
    check sh("bl reach --source ssh://far/" & s.place, blb("(one)")).code == 0
    check sh("bl reach --source ssh://far/tcp://" & s.place & " -- read",
             "(two)").code == 0
    check s.arrived(blb("(one) (two)").len) == blb("(one) (two)")
    discard s.stop

suite "clave":
  let key = tmp / "keys" / "key.blb"
  let values = blb("\"hello\" (a b!) 42! !(go 1) {k: nil!}")

  test "keygen keeps a keypair owner-only and won't overwrite it":
    let r = sh("bl clave keygen --out " & key)
    check r.code == 0
    check "-- public 0x" in r.errors
    check getFilePermissions(key) == {fpUserRead, fpUserWrite}
    check text(readFile(key))[0].head == sym("keypair")
    let again = sh("bl clave keygen --out " & key)
    check again.code == 1
    check "exists" in again.errors
    check sh("bl clave keygen --force --out " & key).code == 0

  test "sign then verify passes every value on, signature and all":
    let signed = sh("bl clave sign --key " & key, values)
    check signed.code == 0
    check signed.output.text.len == 5
    check signed.output.text[1].items[1] == text(blb("(a b!)"))[0]
    let verified = sh("bl clave verify", signed.output)
    check verified.code == 0
    check verified.output == signed.output

  test "a tampered byte fails verify, with the reason":
    var signed = sh("bl clave sign --key " & key, values).output
    signed[signed.find("hello")] = 'j'
    let r = sh("bl clave verify", signed)
    check r.code == 1
    check r.output == ""
    check "signature does not hold" in r.errors
    check sh("bl clave verify", blb("(not signed)")).code == 1

  test "--drop drops what doesn't hold and counts it":
    let good = sh("bl clave sign --key " & key, blb("good")).output
    var bad = sh("bl clave sign --key " & key, blb("\"hello\"")).output
    bad[bad.find("hello")] = 'j'
    let r = sh("bl clave verify --drop", good & bad & blb("(unsigned)"))
    check r.code == 0
    check r.output == good
    check "dropped value 2 (1 so far)" in r.errors
    check "dropped value 3 (2 so far)" in r.errors
    check "-- held 1, dropped 2" in r.errors

  test "nothing may ride along inside the signature either":
    let signed = sh("bl clave sign --key " & key, blb("(pay bob 5)")).output
    var v = text(signed)[0]
    v.items[2].items.add sym("vouched-by-bank")
    let r = sh("bl clave verify", v.ce.toString)
    check r.code == 1
    check "not (signature …) with exactly 3 items" in r.errors
    check sh("bl clave verify --drop", v.ce.toString).output == ""

  test "sign without a key says how to make one":
    let r = sh("bl clave sign --key " & tmp / "nokey.blb", values)
    check r.code == 1
    check "bl clave keygen" in r.errors

# ================ jam ================

proc withEnv(vars: openArray[(string, string)]): StringTableRef =
  ## this process's environment, and `vars`
  result = newStringTable()
  for k, v in envPairs(): result[k] = v
  for (k, v) in vars: result[k] = v

proc jamServe(extra: seq[string] = @["--memory"], at = ":0", home = ""): Serving =
  ## `bl jam serve AT`, once it says where it listens, with `home` as
  ## its HOME if given
  result.p = startProcess(bin / "bl-jam", args = @["serve", at] & extra,
                          env = (if home.len > 0: withEnv({"HOME": home}) else: nil),
                          options = {})
  let said = result.p.errorStream.readLine
  doAssert said.startsWith("-- listening on "), said
  result.place = said["-- listening on ".len .. ^1].split(',')[0]

proc asking(s: Serving, says: string): Socket =
  ## a line to the jam that has said `says`, held open to hear on
  result = newSocket(buffered = false)
  result.connect("127.0.0.1", Port(parseInt(s.port)))
  result.send(says)

proc told(line: Socket): seq[Value] =
  ## what the jam has told the line so far
  text(readFor(cint(line.getFd), 1 shl 20, 400))

proc put(s: Serving, says: string): Ran =
  sh("bl reach --source :" & s.port, says)

proc share(s: Serving, space: string): Process =
  ## `bl jam share SPACE` as kb, on the jam `s`
  startProcess(bin / "bl-jam", args = ["share", space, "--at", ":" & s.port,
                                       "--as", "kb"], options = {})

proc stopShare(p: Process) =
  discard kill(Pid(p.processID), SIGTERM)
  discard p.waitForExit
  p.close()

type Agent = object
  ## `bl jam mcp` as an agent's session drives it
  p: Process
  pending: string
  initialization: JsonNode
  lastResult: JsonNode

proc tell(a: var Agent, j: JsonNode) =
  a.p.inputStream.write($j & "\n")
  a.p.inputStream.flush()

proc next(a: var Agent, ms = 5000): JsonNode =
  ## what it says next, or null once it says nothing for `ms`
  while '\n' notin a.pending:
    let got = readFor(cint(a.p.outputHandle), 65536, ms)
    if got.len == 0: return newJNull()
    a.pending.add got
  let nl = a.pending.find('\n')
  result = parseJson(a.pending[0 ..< nl])
  a.pending = a.pending[nl + 1 .. ^1]

proc call(a: var Agent, id: int, tool: string, args: JsonNode): string =
  ## what a tool answers, passing over what is pushed meanwhile
  a.tell %*{"jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": {"name": tool, "arguments": args}}
  var j = a.next()
  while j.kind != JNull and j{"id"}.getInt(-1) != id: j = a.next()
  a.lastResult = j{"result"}
  a.lastResult{"content"}[0]["text"].getStr

proc pushed(a: var Agent, ms = 1500): seq[JsonNode] =
  ## what it pushes as a channel until it pushes nothing for `ms`
  var j = a.next(ms)
  while j.kind != JNull:
    if j{"method"}.getStr == "notifications/claude/channel": result.add j
    j = a.next(ms)

proc said(pushes: seq[JsonNode]): seq[string] =
  pushes.mapIt(it["params"]["content"].getStr)

proc begun(p: Process, ready = true): Agent =
  ## an MCP server once it has begun
  result.p = p
  result.tell %*{"jsonrpc": "2.0", "id": 0, "method": "initialize",
                 "params": {"protocolVersion": "2025-06-18"}}
  var j = result.next()
  doAssert j{"id"}.getInt(-1) == 0, "initialize must be answered before channel notifications"
  result.initialization = j{"result"}
  if ready: result.tell %*{"jsonrpc": "2.0", "method": "notifications/initialized"}

proc agent(s: Serving, name: string, extra: seq[string] = @[], ready = true): Agent =
  ## `bl jam mcp` as `name` on the jam `s`, once it has begun
  begun(startProcess(bin / "bl-jam", args = @["mcp", "--at", ":" & s.port,
                                             "--as", name] & extra, options = {}), ready)

proc leave(a: var Agent) =
  ## its session ends
  a.p.inputStream.close()
  discard a.p.waitForExit(5000)
  a.p.close()

proc saidBy(vs: seq[Value], room: Value, by = sym"kb"): seq[Value] =
  ## what `by` said in `room`, of the records the jam told
  for v in vs:
    if v.items[0] == room and v.items[2].answer(sym"by") == some by:
      result.add v.items[2].answer(sym"said").get

proc hearUntil(line: Socket, heard: var seq[Value],
               enough: proc(vs: seq[Value]): bool, rounds = 25) =
  ## what the jam tells the line, added to `heard` until it is enough
  for _ in 0 ..< rounds:
    if enough(heard): return
    heard.add line.told

suite "jam":
  test "a jam tells whoever asks what was put, and then what comes":
    let jam = jamServe()
    check jam.put(blb("(general !{(by bob) (said \"hi\")}) (rooms general)")).code == 0
    let line = jam.asking(blb("(general)"))
    check line.told == text(blb("(general 1 !{(by bob) (said \"hi\")})"))   # 0 is its (jam)
    check jam.put(blb("(general later) (random elsewhere) (general later)")).code == 0
    check line.told == text(blb("(general 3 later)"))
    line.close()
    discard jam.stop

  test "a jam with a key stamps what it keeps, under its name":
    let key = tmp / "jam-key.blb"
    check sh("bl clave keygen --out " & key).code == 0
    let jam = jamServe(@["--memory", "--key", key, "--as", "tea"])
    check jam.put(blb("(general !{(by bob) (said \"hi\")})")).code == 0
    let line = jam.asking(blb("((stamps tea)) (here)"))
    let told = line.told
    let stamps = told.filterIt(it.items[0] == readValue("(stamps tea)"))
    check stamps.len == 3                  # its (jam), its here, then bob's hi
    check stamps.mapIt(it.items[1]) == @[toValue(0), toValue(1), toValue(2)]
    let here = told.filterIt(it.items[0] == sym"here")
    check here.len == 1 and here[0].items[2].items[0] == sym"signed"
    check jam.put(blb("((stamps tea) \"mine\")")).code == 0   # carried, and refused there
    line.close()
    check "refused ((stamps tea) \"mine\")" in jam.stop

  test "a line that only speaks is gone once it stops, and its here with it":
    let jam = jamServe()
    let line = jam.asking(blb("(gone)"))
    check jam.put(blb("(here !{(by bob) (at 1)})")).code == 0
    let gone = line.told
    check gone.len == 1 and gone[0].items[0] == sym"gone"
    check gone[0].items[2].answer(sym"by") == some sym"bob"
    line.close()
    discard jam.stop

  test "the log is a run of records, and a jam opened on it holds what it held":
    let log = tmp / "jam.blb"
    var jam = jamServe(@["--log", log])
    check jam.put(blb("(general first)")).code == 0
    discard jam.stop
    let kept = sh("bl cat " & log).output.splitLines
    check kept.len == 3 and kept[0].startsWith("(jam 0 !{") and kept[1] == "(general 1 first)"
    jam = jamServe(@["--log", log])
    check jam.put(blb("(general second)")).code == 0
    let line = jam.asking(blb("(general)"))
    check line.told == text(blb("(general 1 first) (general 2 second)"))
    line.close()
    discard jam.stop

  test "jams are kept by name: --new begins one, --as serves it, and each is served once":
    let home = tmp / "jams-home"
    let homed = "HOME=" & quoteShell(home) & " "
    var r = sh(homed & "bl jam serve --as tea :0")
    check r.code == 1 and "no jam called tea" in r.errors and "--new begins one" in r.errors
    r = sh(homed & "bl jam serve --as ../tea --new :0")
    check r.code == 2 and "a jam's name names its file" in r.errors
    var jam = jamServe(@["--as", "tea", "--new"], home = home)
    let which = jam.asking(blb("(jam)")).told
    check which.len == 1 and which[0].items[1] == toValue(0)
    check which[0].items[2].knownAs(sym"tea")
    check jam.put(blb("(general !{(by bob) (said \"hi\") (at 5)}) (rooms general) " &
                      "(here !{(by bob) (at 6)})")).code == 0
    check jam.put(blb("(jam \"another\")")).code == 0     # carried, and refused there
    r = sh(homed & "bl jam serve --as tea :0")
    check r.code == 1 and ("being served already at " & jam.place) in r.errors
    r = sh(homed & "bl jam serve --as tea --new :0")
    check r.code == 1 and "there is a jam called tea already" in r.errors
    let listed = text(sh(homed & "bl jam list").output)
    check listed.len == 1 and listed[0].items[0] == sym"jam" and listed[0].items[1] == sym"tea"
    let about = listed[0].items[2]
    check about[sym"kept"] == toValue(home / ".bl" / "jams" / "tea.blb")
    check about[sym"served"] == toValue(jam.place)
    check about[sym"rooms"] == readValue("{general}") and about[sym"who"] == readValue("{bob}")
    check about[sym"records"] == toValue(5)         # jam, hi, rooms, here, gone
    check about[sym"began"] == toValue(5)
    check "refused (jam \"another\")" in jam.stop
    check "served" notin sh(homed & "bl jam list | bl cat").output
    jam = jamServe(@["--as", "tea"], home = home)
    check jam.asking(blb("(jam)")).told == which     # the same jam
    discard jam.stop
    jam = jamServe(@[], home = home)                 # the default, made when missing
    check text(sh(homed & "bl jam list").output).mapIt(it.items[1]) == @[sym"jam", sym"tea"]
    discard jam.stop

  test "an agent stays with its jam: another served at its place is hung up on":
    let home = tmp / "jams-home"
    var one = jamServe(@["--as", "one", "--new"], home = home)
    let port = one.port
    var a = one.agent("stayer")
    check a.call(1, "tell", %*{"value": "(general !{(by stayer) (said \"on one\")})"}).
      startsWith("(put general ")
    discard one.stop
    let two = jamServe(@["--as", "two", "--new"], at = ":" & port, home = home)
    let r = a.call(2, "tell", %*{"value": "(general !{(by stayer) (said \"on two?\")})"})
    check ("the jam at 127.0.0.1:" & port & " is two now, not one") in r
    check two.asking(blb("(here) (general)")).told.len == 0   # it said nothing there
    discard two.stop
    one = jamServe(@["--as", "one"], at = ":" & port, home = home)
    check a.call(3, "tell", %*{"value": "(general !{(by stayer) (said \"back\")})"}).
      startsWith("(put general ")
    let line = one.asking(blb("(general)"))
    check line.told.mapIt(it.items[2].answer(sym"said").get) == @[toValue("on one"), toValue("back")]
    a.leave
    discard one.stop

  test "with --clave, only values bl clave signed are taken":
    let key = tmp / "jamkey.blb"
    discard sh("bl clave keygen --out " & key)
    let jam = jamServe(@["--memory", "--clave"])
    check jam.put(blb("(general unsigned)")).code == 0
    check sh("bl clave sign --key " & key & " | bl reach --source :" & jam.port,
             blb("(general signed)")).code == 0
    let ask = sh("bl clave sign --key " & key, blb("(general)")).output
    let line = jam.asking(ask)
    let heard = line.told
    check heard.len == 1
    check heard[0].items[2].head == sym"signed"
    check heard[0].items[2].items[1] == text(blb("(general signed)"))[0]
    line.close()
    check "refused (general unsigned)" in jam.stop

  test "bl jam mcp: two tools, tell and heard, and what is said to it as a channel":
    let jam = jamServe()
    var a = jam.agent("agent-1")
    check a.call(1, "tell", %*{"value": "(general !{(by agent-1) (said \"hello\")})"}) ==
      "(put general 2)"                    # 0 is the jam's (jam), 1 its here
    check a.call(2, "tell", %*{"value": "(elsewhere)"}) == "(asked elsewhere 0)"
    check "a jam takes (Q A) to put and (Q) to ask" in a.call(3, "tell", %*{"value": "(a b c)"})
    check jam.put(blb("(general !{(by alice) (said \"over to you\") (for agent-1)})")).code == 0
    let pushed = a.pushed
    check pushed.len == 1
    let r = readValue(pushed[0]["params"]["content"].getStr)
    check r.items[0] == sym"heard" and r.items[1] == sym"general"
    check r.items[4].answer(sym"said") == some toValue("over to you")
    check r.items[3].dict[sym"to-you"] == sym"named"
    check r.items[3].dict[sym"by"] == sym"alice"
    check pushed[0]["params"]["meta"]["by"].getStr == "alice"
    check a.call(8, "tell", %*{"value": "(general !{(by agent-1) (said \"to all\") (for all)})"}).
      startsWith("(put general ")
    let found = a.call(4, "heard", %*{"shape": "(shape (heard q r x !{(by b) (for agent-1)}) {q r x b})"})
    check found.splitLines.len == 1 and "over to you" in found
    check a.call(5, "heard", %*{"shape": "(shape (heard q r {to-you: w}) {q r w})"}) == found
    a.tell %*{"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "heard",
              "arguments": {"shape": "(shape (heard q r {to-you: w}) {q r w})", "wait": 30}}}
    let now = a.call(7, "heard", %*{"shape": "(shape (heard here) {})"})
    check "agent-1" in now                 # a held heard holds no other call up
    check jam.put(blb("(general !{(by alice) (said \"everyone, look\") (for all)})")).code == 0
    var waited = a.next()
    while waited{"method"}.getStr == "notifications/claude/channel": waited = a.next()
    check waited{"id"}.getInt == 6
    let late = waited{"result", "content"}[0]["text"].getStr
    check "everyone, look" in late and "over to you" notin late
    a.leave()
    discard jam.stop

  test "bl jam mcp: channel records wait for initialized, including replay and new records":
    let jam = jamServe()
    check jam.put(blb("(general !{(by alice) (said \"before initialize\") (for waiting-agent)})")).code == 0
    var a = jam.agent("waiting-agent", ready = false)
    check a.initialization{"capabilities", "experimental", "claude/channel"} != nil
    check a.next(200).kind == JNull
    check jam.put(blb("(general !{(by alice) (said \"before initialized\") (for waiting-agent)})")).code == 0
    check a.next(200).kind == JNull
    a.tell %*{"jsonrpc": "2.0", "method": "notifications/initialized"}
    let pushed = a.pushed.said
    check pushed.len == 2
    check "before initialize" in pushed[0]
    check "before initialized" in pushed[1]
    a.tell %*{"jsonrpc": "2.0", "method": "notifications/initialized"}
    check a.next(100).kind == JNull          # initialization doesn't replay twice
    a.leave()
    discard jam.stop

  test "bl jam mcp: push none keeps tools and waits, without a Claude capability or notifications":
    let jam = jamServe()
    check jam.put(blb("(general !{(by alice) (said \"past\") (for tool-agent)})")).code == 0
    var a = jam.agent("tool-agent", @["--push", "none", "--hear", "all"])
    check a.initialization{"capabilities", "experimental"} == nil
    check a.initialization{"capabilities", "tools"} != nil
    check "Standard MCP tools provide delivery when you ask" in a.initialization{"instructions"}.getStr
    check "<channel" notin a.initialization{"instructions"}.getStr
    check a.next(200).kind == JNull
    let past = a.call(1, "heard", %*{"shape": "(shape (heard q r {to-you: w}) {q r w})"})
    check "past" in past
    check a.call(2, "tell", %*{"value": "(general !{(by tool-agent) (said \"working\")})"}).startsWith("(put general ")
    a.tell %*{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "heard",
              "arguments": {"shape": "(shape (heard q r {to-you: w}) {q r w})", "wait": 30}}}
    check "tool-agent" in a.call(4, "heard", %*{"shape": "(shape (heard here) {})"})
    check jam.put(blb("(general !{(by alice) (said \"new\") (for tool-agent)})")).code == 0
    let waited = a.next()
    check waited{"id"}.getInt == 3
    check "new" in waited{"result", "content"}[0]["text"].getStr
    check a.next(100).kind == JNull
    a.leave()
    discard jam.stop

  test "bl jam mcp: heard metadata names its effective edge and current hello barrier, including waits":
    let jam = jamServe()
    var a = jam.agent("metadata-agent", @["--push", "none"])
    let joined = readValue(a.call(1, "heard", %*{"shape": "(shape (heard here) {})", "first": 1,
                                               "since": -1, "wait": 2}))
    let metadata = a.lastResult{"_meta", "jam"}
    check metadata{"name"}.getStr == "metadata-agent"
    check metadata{"place"}.getStr == "127.0.0.1:" & jam.port
    check metadata{"joinedRank"}.getInt(-1) == joined.items[2].num.toInt
    check metadata{"joinedRank"}.getInt(-1) >= 0
    a.tell %*{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "heard",
              "arguments": {"shape": "(shape (heard q r {to-you: w}) {q r w})", "wait": 30}}}
    check jam.put(blb("(general !{(by alice) (said \"later\") (for metadata-agent)})")).code == 0
    let waited = a.next()
    check waited{"id"}.getInt == 2
    check waited{"result", "_meta", "jam"} == metadata
    let later = readValue(waited{"result", "content"}[0]["text"].getStr)
    check later.items[2].num.toInt > metadata{"joinedRank"}.getInt
    a.leave()
    discard jam.stop

  test "bl jam mcp: first drains the oldest matches without skipping a backlog larger than last's default":
    let jam = jamServe()
    var records = ""
    for i in 0 ..< 41: records.add "(general (item " & $i & ")) "
    check jam.put(blb(records)).code == 0
    var a = jam.agent("drain-agent", @["--push", "none"])
    let shape = "(shape (heard general) {})"
    # its here is told after the joined room's history, so the whole backlog is ready
    discard a.call(1, "heard", %*{"shape": "(shape (heard here) {})", "first": 1, "since": -1, "wait": 2})
    let newest = a.call(2, "heard", %*{"shape": shape}).splitLines.mapIt(readValue(it))
    check newest.len == 30
    check newest[0].items[4] == readValue("(item 11)")
    var since = -1
    var found: seq[Value]
    for batch in 0 ..< 5:
      let page = a.call(3 + batch, "heard", %*{"shape": shape, "first": 9, "since": since}).splitLines
      for line in page:
        let r = readValue(line)
        found.add r.items[4]
        since = r.items[2].num.toInt
    check found.len == 41
    for i, v in found: check v == readValue("(item " & $i & ")")
    check a.call(8, "heard", %*{"shape": shape, "first": 9, "since": since}) == "nothing heard fits"
    check a.call(9, "heard", %*{"shape": shape, "last": 0}) == "nothing heard fits"
    a.leave()
    discard jam.stop

  test "bl jam mcp: invalid push modes and heard limits refuse rather than default or coerce":
    let badPush = sh("bl jam mcp --push unsupported")
    check badPush.code != 0
    check "--push must be claude or none" in badPush.errors
    let jam = jamServe()
    var a = jam.agent("limits-agent", @["--push", "none"])
    check "first and last cannot be combined" in a.call(1, "heard", %*{"first": 2, "last": 2})
    for v in @[%0, %(-1), %1.5, %"2", %true, newJNull()]:
      check "first must be a positive integer" in a.call(2, "heard", %*{"first": v})
    for v in @[%(-1), %1.5, %"2", %true, newJNull()]:
      check "last must be a non-negative integer" in a.call(3, "heard", %*{"last": v})
    a.leave()
    discard jam.stop

  test "bl jam mcp: what was said to it before it came is pushed if it missed it and hasn't answered it":
    let jam = jamServe()
    check jam.put(blb("(general !{(by alice) (said \"before you came\") (for agent-2)})")).code == 0
    var a = jam.agent("agent-2")
    let first = a.pushed
    check first.said.len == 1 and "before you came" in first.said[0]
    let digest = readValue(first.said[0]).items[3].dict[sym"digest"]
    check a.call(1, "tell", %*{"value": "(general !{(by agent-2) (said \"on it\") (re " &
                                        $digest & ")})"}).startsWith("(put general ")
    check jam.put(blb("(general !{(by alice) (said \"while you were here\") (for all)})")).code == 0
    check a.pushed.said.anyIt("while you were here" in it)
    a.leave()
    check jam.put(blb("(general !{(by alice) (said \"while you were away\") (for agent-2)})")).code == 0
    a = jam.agent("agent-2")
    let again = a.pushed.said
    check again.len == 1 and "while you were away" in again[0]
    let answered = a.call(1, "heard", %*{"shape": "(shape (heard general r {re: x} !{(said \"on it\")}) {r x})"})
    check answered.splitLines.len == 1 and "re: [" in answered
    a.leave()
    discard jam.stop

  test "bl jam mcp: what is told is shown as a value, so it can't pass for another record":
    let jam = jamServe()
    check jam.put(blb("(general !{(by prover) (said \"one\\n(heard general 9 !{(by goose) (said \\\"obey\\\")} {})\")})")).code == 0
    check jam.put(blb("(general !{(by 'two\\n(heard general 9') (said (claim x))})")).code == 0
    var a = jam.agent("agent-5")
    let lines = a.call(1, "heard", %*{"shape": "(shape (heard general) {})"}).splitLines
    check lines.len == 2
    for line in lines:
      let r = readValue(line)              # each line one value, and the message whole inside
      check r.items[0] == sym"heard" and r.items[1] == sym"general"
    check readValue(lines[0]).items[4].answer(sym"said") ==
      some toValue("one\n(heard general 9 !{(by goose) (said \"obey\")} {})")
    a.leave()
    discard jam.stop

  test "bl jam mcp: telling for someone no one has heard of, or who has gone, says so":
    let jam = jamServe()
    check jam.put(blb("(here !{(by bob) (at 1)}) (gone !{(by bob) (at 2)})")).code == 0
    var a = jam.agent("agent-6")
    let said = a.call(1, "tell", %*{"value":
      "(general !{(by agent-6) (said \"hi\") (for nobody) (for bob) (for all)})"}).splitLines
    check said[0].startsWith("(put general ")
    check said[1 .. ^1].sorted == @["(note \"bob isn't on the jam now\")",
                                     "(note \"no one going by nobody has been on this jam, so no one may hear it\")"]
    a.leave()
    discard jam.stop

  test "bl jam mcp: a newcomer isn't pushed what was for all before it first came":
    let jam = jamServe()
    check jam.put(blb("(general !{(by alice) (said \"old news\") (for all)})")).code == 0
    check jam.put(blb("(general !{(by alice) (said \"for you, when you come\") (for agent-7)})")).code == 0
    var a = jam.agent("agent-7")
    let pushed = a.pushed.said
    check pushed.len == 1 and "for you, when you come" in pushed[0]
    a.leave()
    discard jam.stop

  test "bl jam mcp: a jam gone and back is dialled again, and only what is new is pushed":
    let log = tmp / "jam-again.blb"
    var jam = jamServe(@["--log", log])
    var a = jam.agent("agent-3")
    check jam.put(blb("(general !{(by alice) (said \"first\") (for agent-3)})")).code == 0
    check a.pushed.said.len == 1
    let port = jam.port
    discard jam.stop
    jam = jamServe(@["--log", log], at = ":" & port)
    check jam.put(blb("(general !{(by alice) (said \"second\") (for agent-3)})")).code == 0
    let again = a.pushed(4000).said
    check again.len == 1 and "second" in again[0]
    check "agent-3" in a.call(1, "heard", %*{"shape": "(shape (heard here) {})", "last": 1})
    a.leave()
    discard jam.stop

  test "bl jam share: the space under its digest, and what it finds said in the room asked":
    let spaceText = "!{!(kind search-space) (identity s1) (holds {(k 1) (k 2) (help \"ask k\")})}"
    let space = file("space.bl", spaceText)
    let d = digest(readValue(spaceText), Blake2bAlgo).toValue
    let jam = jamServe()
    let kb = jam.share(space)
    let line = jam.asking(blb("(knowledge) (general) (" & $d & ")"))
    var heard: seq[Value]
    line.hearUntil(heard, proc(vs: seq[Value]): bool = vs.saidBy(sym"general").len > 0)
    check heard.anyIt(it.items[0] == sym"knowledge" and it.items[2] == d)
    check heard.anyIt(it.items[0] == d and it.items[2] == readValue(spaceText))
    let hello = heard.saidBy(sym"general")
    check hello.len == 1
    check hello[0].head == sym"sharing" and hello[0].items[1] == d
    check "ask k" in hello[0].items[2].text
    check jam.put(blb("(general !{(by bob) (said k) (at 1) (for kb)}) " &
                      "(general !{(by bob) (said j) (at 2) (for kb)}) " &
                      "(general !{(by bob) (said k) (at 3)}) " &
                      "(general !{(by bob) (said (found k {9})) (at 4) (for kb)}) " &
                      "(general !{(by bob) (said (sharing x \"hi\")) (at 5) (for kb)})")).code == 0
    line.hearUntil(heard, proc(vs: seq[Value]): bool = vs.saidBy(sym"general").len >= 3)
    var said = heard.saidBy(sym"general")
    check said.len == 3
    check said[1] == readValue("(found k {1 2})")
    check said[2] == readValue("(found j {})")
    let byKb = heard.filterIt(it.items[0] == sym"general" and
                              it.items[2].answer(sym"by") == some sym"kb")
    check byKb[1].items[2].answer(sym"for") == some sym"bob"
    # a question re what kb said is a question all the same
    let re = digest(byKb[1].items[2], Blake2bAlgo).toValue
    check jam.put(blb("(general !{(by carol) (said k) (at 6) (for kb) (re " & $re & ")})")).code == 0
    line.hearUntil(heard, proc(vs: seq[Value]): bool = vs.saidBy(sym"general").len >= 4)
    said = heard.saidBy(sym"general")
    check said.len == 4 and said[3] == readValue("(found k {1 2})")
    line.close()
    kb.stopShare()
    discard jam.stop

  test "bl jam share: past the most it says, every answer is put on the jam":
    var holds = ""
    for i in 0 .. 200: holds.add "(k " & $i & ") "
    let space = file("wide.bl", "!{!(kind search-space) (identity s2) (holds {" & holds & "})}")
    let jam = jamServe()
    let kb = jam.share(space)
    let line = jam.asking(blb("(general) ((found k))"))
    var heard: seq[Value]
    line.hearUntil(heard, proc(vs: seq[Value]): bool = vs.saidBy(sym"general").len > 0)
    check jam.put(blb("(general !{(by bob) (said k) (at 1) (for kb)})")).code == 0
    line.hearUntil(heard, proc(vs: seq[Value]): bool = vs.saidBy(sym"general").len > 1)
    let found = heard.saidBy(sym"general")[1]
    check found.items[2].els.len == 200
    check found.items[3] == readValue("(more (found k))")
    line.hearUntil(heard, proc(vs: seq[Value]): bool =
      vs.countIt(it.items[0] == readValue("(found k)")) == 201)
    check heard.countIt(it.items[0] == readValue("(found k)")) == 201
    line.close()
    kb.stopShare()
    discard jam.stop

  test "bl jam share: who comes is told once, and what was said while it was away is taken up":
    let space = file("space3.bl", "!{!(kind search-space) (identity s3) (holds {(k 1)})}")
    let jam = jamServe()
    var kb = jam.share(space)
    let line = jam.asking(blb("(general) ((for carol))"))
    var heard: seq[Value]
    line.hearUntil(heard, proc(vs: seq[Value]): bool = vs.saidBy(sym"general").len > 0)
    check jam.put(blb("(general !{(by bob) (said k) (at 1) (for kb)}) " &
                      "(here !{(by carol) (at 1)}) (here !{(by carol) (at 2)})")).code == 0
    line.hearUntil(heard, proc(vs: seq[Value]): bool =
      vs.saidBy(sym"general").len > 1 and vs.saidBy(readValue("(for carol)")).len > 0)
    check heard.saidBy(readValue("(for carol)")).len == 1
    check heard.saidBy(readValue("(for carol)"))[0].head == sym"sharing"
    kb.stopShare()
    check jam.put(blb("(general !{(by bob) (said nothing-yet) (at 2) (for kb)})")).code == 0
    kb = jam.share(space)
    line.hearUntil(heard, proc(vs: seq[Value]): bool = vs.saidBy(sym"general").len > 2)
    line.hearUntil(heard, proc(vs: seq[Value]): bool = false, rounds = 3)
    let said = heard.saidBy(sym"general")
    check said.len == 3
    check said[2] == readValue("(found nothing-yet {})")
    line.close()
    kb.stopShare()
    discard jam.stop

  test "bl jam needs a terminal, and says how a pipe speaks to one":
    let r = sh("bl jam")
    check r.code == 1
    check "bl reach" in r.errors



suite "jam plugin":
  let plugin = bin / ".." / ".." / "jam-plugin" / "bin"
  let home = tmp / "home"

  test "claude-jam keeps one key for a name, made the first time it comes":
    fake "claude", "echo \"$@\""
    let run = proc(name: string): tuple[output: string, exitCode: int] =
      execCmdEx(quoteShell(plugin / "claude-jam") & " " & quoteShell(name) & " --continue",
                env = withEnv({"HOME": home}))
    let r = run("tester")
    check r.exitCode == 0
    check "--continue --dangerously-load-development-channels plugin:jam@skills-dir" in r.output
    let key = home / ".bl" / "keys" / "tester.blb"
    check fileExists(key)
    check getFilePermissions(key) == {fpUserRead, fpUserWrite}
    let first = readFile(key)
    check run("tester").exitCode == 0
    check readFile(key) == first               # kept, not made again
    let bad = run("../tester")
    check "speaks unsigned" in bad.output
    check toSeq(walkDir(home / ".bl" / "keys")).len == 1

  test "jam-mcp signs with the key kept for its name, and speaks unsigned without one":
    let jam = jamServe()
    let line = jam.asking(blb("(general)"))
    var signing = begun startProcess(plugin / "jam-mcp", args = ["--at", ":" & jam.port],
                                     env = withEnv({"HOME": home, "JAM_NAME": "tester"}),
                                     options = {})
    let kp = Keypair.fromValue(text(readFile(home / ".bl" / "keys" / "tester.blb"))[0])
    let me = "!{(identity tester) (identity " & $bytes(@(kp.pubkey)) & ")}"
    check signing.call(1, "tell", %*{"value": "(general !{(by " & me & ") (said \"signed hi\")})"}).
      startsWith("(put general ")
    var plain = begun startProcess(plugin / "jam-mcp", args = ["--at", ":" & jam.port],
                                   env = withEnv({"HOME": home, "JAM_NAME": "keyless"}),
                                   options = {})
    check plain.call(1, "tell", %*{"value": "(general !{(by keyless) (said \"plain hi\")})"}).
      startsWith("(put general ")
    let told = line.told
    check told.len == 2
    check told[0].items[2].kind == bRec and told[0].items[2].items[0] == sym"signed"
    check heard(told[0]).get.vouched
    check told[1].items[2].answer(sym"by") == some sym"keyless"
    signing.leave()
    plain.leave()
    line.close()
    discard jam.stop

# ================ ws ================

const WsClient = """
// node wsclient.mjs URL ORIGIN WANT HEX…: each HEX as a binary frame, what happens as JSON
const [url, origin, want, ...sends] = process.argv.slice(2)
const ws = new WebSocket(url, origin ? { headers: { Origin: origin } } : undefined)
ws.binaryType = 'arraybuffer'
const out = []
let got = 0
const done = () => { console.log(JSON.stringify(out)); process.exit(0) }
ws.onopen = () => {
  out.push({ open: true })
  for (const h of sends) ws.send(Buffer.from(h, 'hex'))
  if (+want === 0) setTimeout(() => ws.close(), 300)
}
ws.onmessage = e => {
  out.push({ frame: Buffer.from(e.data).toString('hex') })
  if (++got >= +want) ws.close()
}
ws.onerror = () => out.push({ error: true })
ws.onclose = e => { out.push({ close: e.code }); done() }
setTimeout(() => { out.push({ timeout: true }); done() }, +(process.env.WAIT ?? 5000))
"""

proc wsDoor(behind: Serving, extra: seq[string] = @[]): Serving =
  ## `bl ws :0` carrying to `behind`, once it says where it listens
  result.p = startProcess(bin / "bl", args = @["ws", ":0", "--to", ":" & behind.port] & extra,
                          options = {})
  let said = result.p.errorStream.readLine
  doAssert said.startsWith("-- listening on "), said
  result.place = said["-- listening on ".len .. ^1].split(',')[0]

proc hex(ce: string): string = ce.toHex.toLowerAscii

proc page(door: Serving, origin: string, want: int, sends: seq[string],
          wait = 5000): Process =
  ## a page's WebSocket through `door`, from Node's own client: it sends
  ## each CE string as a binary frame and closes once `want` frames came
  writeFile(tmp / "wsclient.mjs", WsClient)
  putEnv("WAIT", $wait)
  startProcess("node", args = @[tmp / "wsclient.mjs", "ws://" & door.place & "/",
                                origin, $want] & sends.mapIt(hex(it)),
               options = {poUsePath})

proc saw(p: Process): JsonNode =
  ## what the page saw, once it has finished
  result = parseJson(p.outputStream.readAll)
  discard p.waitForExit
  p.close()

proc frames(saw: JsonNode): seq[string] =
  for e in saw: (if e.hasKey("frame"): result.add e["frame"].getStr)

proc opened(saw: JsonNode): bool = saw.getElems.anyIt(it.hasKey("open"))

const RfcKey = "dGhlIHNhbXBsZSBub25jZQ=="   # RFC 6455's own example

proc opening(key = RfcKey, origin = "", version = "13", upgrade = true): string =
  result = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n"
  if upgrade: result.add "Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n"
  result.add "Sec-WebSocket-Key: " & key & "\r\nSec-WebSocket-Version: " & version & "\r\n"
  if origin.len > 0: result.add "Origin: " & origin & "\r\n"
  result.add "\r\n"

type Raw = object
  ## a WebSocket spoken by hand, for what Node's client won't do
  s: Socket
  head, rest: string

proc raw(door: Serving, request = opening()): Raw =
  result.s = newSocket(buffered = false)
  result.s.connect("127.0.0.1", Port(parseInt(door.port)))
  result.s.send(request)
  var got = ""
  while "\r\n\r\n" notin got:
    let more = readFor(cint(result.s.getFd), 65536, 2000)
    if more.len == 0: break
    got.add more
  let cut = got.find("\r\n\r\n")
  result.head = if cut >= 0: got[0 ..< cut] else: got
  result.rest = if cut >= 0: got[cut + 4 .. ^1] else: ""

proc frame(op: int, payload: string, fin = true, mask = true): string =
  ## a frame as a page sends it
  result.add char((if fin: 0x80 else: 0) or op)
  let m = if mask: 0x80 else: 0
  let n = payload.len
  if n < 126: result.add char(m or n)
  elif n <= 0xFFFF:
    result.add char(m or 126)
    result.add char(n shr 8)
    result.add char(n and 0xFF)
  else:
    result.add char(m or 127)
    for i in countdown(7, 0): result.add char((n shr (8 * i)) and 0xFF)
  if mask:
    let key = "\x11\x22\x33\x44"
    result.add key
    for i, c in payload: result.add char(c.byte xor key[i and 3].byte)
  else: result.add payload

proc heard(r: var Raw, ms = 1500): seq[(int, string)] =
  ## the frames the door has sent, as (opcode, payload), until it says
  ## nothing for `ms` or has closed
  var data = r.rest
  r.rest = ""
  while true:
    let more = readFor(cint(r.s.getFd), 1 shl 20, ms)
    if more.len == 0: break
    data.add more
  var i = 0
  while i + 2 <= data.len:
    let op = data[i].int and 0x0F
    var n = data[i + 1].int and 0x7F
    i += 2
    if n == 126:
      n = (data[i].int shl 8) or data[i + 1].int
      i += 2
    elif n == 127:
      n = 0
      for k in 0 .. 7: n = (n shl 8) or data[i + k].int
      i += 8
    if i + n > data.len: break
    result.add (op, data[i ..< i + n])
    i += n

proc closeCode(frames: seq[(int, string)]): int =
  for (op, p) in frames:
    if op == 0x8 and p.len >= 2: return (p[0].int shl 8) or p[1].int
  -1

suite "ws":
  if findExe("node").len == 0:
    echo "  (node isn't on PATH; the page tests need its WebSocket client)"

  test "a page reaches a jam through the door, a value a frame each way":
    let jam = jamServe()
    let door = wsDoor(jam)
    let saw = door.page("http://localhost:5173", 2,
                        @[blb("(general \"hi\") (general)"), blb("(general \"again\")")]).saw
    check saw.frames == @[hex(blb("(general 1 \"hi\")")), hex(blb("(general 2 \"again\")"))]
    check saw[^1]{"close"}.getInt == 1000
    discard door.stop
    discard jam.stop

  test "a message that isn't whole CE isn't carried, and the door carries on":
    let jam = jamServe()
    let door = wsDoor(jam)
    let whole = blb("(general \"cut short\")")
    let saw = door.page("http://localhost:5173", 1,
                        @[whole[0 .. 3], "\xf0", blb("(general \"b\") (general)")]).saw
    check saw.frames == @[hex(blb("(general 1 \"b\")"))]
    let said = door.stop
    check "ends partway through a value, not carried" in said
    check "isn't CE, not carried" in said
    discard jam.stop

  test "an origin that fits no pattern is refused; one that fits, or none, is let in":
    let jam = jamServe()
    let door = wsDoor(jam)
    let evil = door.page("http://evil.example", 1, @[blb("(general \"no\")")]).saw
    check not evil.opened and evil.frames.len == 0
    check door.page("http://127.0.0.1:8080", 0, @[]).saw.opened
    check door.page("", 0, @[]).saw.opened       # a program, not a page
    let said = door.stop
    check "origin http://evil.example isn't allowed" in said
    let only = wsDoor(jam, @["--origin", "http://*.app.test:*", "--origin", "https://app.test"])
    check not only.page("http://localhost:5173", 0, @[]).saw.opened
    check only.page("http://x.app.test:8080", 0, @[]).saw.opened
    check only.page("https://app.test", 0, @[]).saw.opened
    check not only.page("http://a.b.app.test:8080", 0, @[]).saw.opened
    check not only.page("http://x.app.test:8080.evil.com", 0, @[]).saw.opened
    discard only.stop
    discard jam.stop

  test "when the place behind ends the page's WebSocket ends, and when the page goes its line goes":
    var jam = jamServe()
    let door = wsDoor(jam)
    let line = jam.asking(blb("(gone)"))
    discard door.page("http://localhost:5173", 0, @[blb("(here !{(by page) (at 1)})")]).saw
    let gone = line.told
    check gone.len == 1 and gone[0].items[2].answer(sym"by") == some sym"page"
    line.close()
    let waiting = door.page("http://localhost:5173", 5, @[blb("(general)")], wait = 8000)
    sleep 500
    discard jam.stop
    let saw = waiting.saw
    check saw.opened and saw[^1]{"close"}.getInt == 1000
    discard door.stop

  test "the opening: RFC 6455's own key, a plain GET, another version, nothing behind":
    let jam = jamServe()
    let door = wsDoor(jam)
    var r = door.raw()
    check r.head.startsWith("HTTP/1.1 101")
    check "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" in r.head
    r.s.close()
    check door.raw(opening(upgrade = false)).head.startsWith("HTTP/1.1 400")
    let old = door.raw(opening(version = "8")).head
    check old.startsWith("HTTP/1.1 426") and "Sec-WebSocket-Version: 13" in old
    check door.raw(opening(origin = "http://evil.example")).head.startsWith("HTTP/1.1 403")
    let port = jam.port
    discard jam.stop
    check door.raw().head.startsWith("HTTP/1.1 502")
    check "can't reach 127.0.0.1:" & port in door.stop

  test "frames: fragments and a ping between them, and lengths past 125 and 65535":
    let jam = jamServe()
    let door = wsDoor(jam)
    var r = door.raw()
    let msg = blb("(general \"split\") (general)")
    let half = msg.len div 2
    r.s.send(frame(0x2, msg[0 ..< half], fin = false) & frame(0x9, "p") &
             frame(0x0, msg[half .. ^1]))
    check r.heard == @[(0xA, "p"), (0x2, blb("(general 1 \"split\")"))]
    let mid = blb("(general \"" & 'm'.repeat(300) & "\")")
    let big = blb("(general \"" & 'b'.repeat(70_000) & "\")")
    r.s.send(frame(0x2, mid) & frame(0x2, big))
    check r.heard == @[(0x2, blb("(general 2 \"" & 'm'.repeat(300) & "\")")),
                       (0x2, blb("(general 3 \"" & 'b'.repeat(70_000) & "\")"))]
    r.s.send(frame(0x8, "\x03\xe8"))
    check r.heard.closeCode == 1000
    r.s.close()
    discard door.stop
    discard jam.stop

  test "frames: unmasked, text, or past --max-value end the WebSocket, saying why":
    let jam = jamServe()
    let door = wsDoor(jam, @["--max-value", "100"])
    var r = door.raw()
    r.s.send(frame(0x2, blb("(general)"), mask = false))
    check r.heard.closeCode == 1002
    r.s.close()
    r = door.raw()
    r.s.send(frame(0x1, "(general)"))
    check r.heard.closeCode == 1003
    r.s.close()
    r = door.raw()
    r.s.send(frame(0x2, blb("(general \"" & 'x'.repeat(200) & "\")")))
    check r.heard.closeCode == 1009
    r.s.close()
    let said = door.stop
    check "an unmasked frame" in said and "a text frame" in said and "past 100 bytes" in said
    discard jam.stop

  test "a door listens on this machine only":
    for place in ["0.0.0.0:0", "127.lan:0", "[::1]:0"]:
      let r = sh("bl ws " & place)
      check r.code == 2
      check "loopback" in r.errors
    let jam = jamServe()
    let door = startProcess(bin / "bl", args = ["ws", "localhost:0", "--to", ":" & jam.port],
                            options = {})
    check door.errorStream.readLine.startsWith("-- listening on 127.0.0.1:")
    discard kill(Pid(door.processID), SIGTERM)
    discard door.waitForExit
    door.close()
    discard jam.stop

  test "the default origins let in only pages on this machine, over http":
    let jam = jamServe()
    let door = wsDoor(jam)
    proc answered(origin: string): string =
      let r = door.raw(opening(origin = origin))
      r.s.close()
      r.head
    for origin in ["http://localhost.evil.com:5173", "http://127.0.0.1.evil.com:80", "null",
                   "https://localhost:5173", "http://localhost", "http://localhost:5173/x"]:
      check answered(origin).startsWith("HTTP/1.1 403")
    for origin in ["http://localhost:5173", "http://127.0.0.1:8080"]:
      check answered(origin).startsWith("HTTP/1.1 101")
    discard door.stop
    discard jam.stop

  test "a message holding a whole value and then a bad tail carries none of it":
    let jam = jamServe()
    let door = wsDoor(jam)
    var r = door.raw()
    r.s.send(frame(0x2, blb("(general \"first\")") & "\xf0"))
    r.s.send(frame(0x2, blb("(general \"ok\") (general)")))
    check r.heard == @[(0x2, blb("(general 1 \"ok\")"))]   # first never got in
    r.s.close()
    discard door.stop
    discard jam.stop

  test "frames against the protocol end the WebSocket with 1002":
    let jam = jamServe()
    let door = wsDoor(jam)
    proc closesWith(bytes: string): int =
      var r = door.raw()
      r.s.send(bytes)
      result = r.heard.closeCode
      r.s.close()
    let reserved = block:
      var f = frame(0x2, blb("(general)"))
      f[0] = char(f[0].int or 0x40)
      f
    check closesWith(reserved) == 1002
    check closesWith(frame(0x3, "")) == 1002                       # no such opcode
    check closesWith(frame(0x9, 'p'.repeat(126))) == 1002          # a ping past 125
    check closesWith(frame(0x9, "p", fin = false)) == 1002         # a ping in pieces
    check closesWith(frame(0x0, blb("(general)"))) == 1002         # a continuation first
    check closesWith(frame(0x2, "a", fin = false) & frame(0x2, "b")) == 1002   # a new message mid-message
    check closesWith(frame(0x8, "\x03")) == 1002                   # a close of one byte
    check closesWith(frame(0x8, "\x03\xed")) == 1002               # 1005, never sent
    check closesWith(frame(0x8, "\x0f\xa0")) == 4000               # an application's own
    discard door.stop
    discard jam.stop

  test "--max-value bounds a message, a length only claimed holds nothing, and a ping between fragments isn't counted":
    let jam = jamServe()
    let msg = blb("(general \"" & 'x'.repeat(80) & "\") (general)")
    let door = wsDoor(jam, @["--max-value", $(msg.len + 5)])
    var r = door.raw()
    r.s.send(frame(0x2, msg[0 ..< msg.len - 2], fin = false) & frame(0x9, 'p'.repeat(20)) &
             frame(0x0, msg[msg.len - 2 .. ^1]))
    check r.heard == @[(0xA, 'p'.repeat(20)), (0x2, blb("(general 1 \"" & 'x'.repeat(80) & "\")"))]
    r.s.close()
    r = door.raw()
    r.s.send("\x82\xff\x00\x00\x01\x00\x00\x00\x00\x00")    # claims 2^40 bytes
    check r.heard.closeCode == 1009
    r.s.close()
    discard door.stop
    discard jam.stop

  test "connections reset as they are accepted leave nothing open":
    let jam = jamServe()
    let door = wsDoor(jam)
    proc sockets(): int =
      let r = execCmdEx("lsof -nP -a -p " & $door.p.processID & " -i")
      max(0, r.output.strip.splitLines.len - 1)
    let before = sockets()
    for _ in 0 ..< 100:
      let s = newSocket(buffered = false)
      s.connect("127.0.0.1", Port(parseInt(door.port)))
      var linger = TLinger(l_onoff: 1, l_linger: 0)
      discard setsockopt(s.getFd, SOL_SOCKET, SO_LINGER, addr linger, SockLen(sizeof(linger)))
      s.close()
    sleep 1000
    check sockets() <= before
    check door.page("http://localhost:5173", 0, @[]).saw.opened
    discard door.stop
    discard jam.stop

  test "a place behind that takes in nothing holds the door to a window, and is ended after --stall":
    let stuck = newSocket()
    stuck.setSockOpt(OptReuseAddr, true)
    stuck.bindAddr(Port(0), "127.0.0.1")
    stuck.listen()
    let behind = Serving(place: "127.0.0.1:" & $int(stuck.getLocalAddr()[1]))
    let door = wsDoor(behind, @["--stall", "1"])
    var r = door.raw()
    var taken: Socket
    stuck.accept(taken)                          # and never read
    let big = frame(0x2, blb("(general \"" & 'x'.repeat(1 shl 20) & "\")"))
    for _ in 0 ..< 40:
      try: r.s.send(big, flags = {})            # raising, not spinning, once the door has gone
      except CatchableError: break
    check r.heard(3000).closeCode == 1011
    let rss = execCmdEx("ps -o rss= -p " & $door.p.processID).output.strip.parseInt
    check rss < 100_000                          # in KB: a window, not 40 MB
    r.s.close()
    let said = door.stop
    check "takes in nothing" in said
    taken.close()
    stuck.close()

  test "a page that takes in nothing is ended once a window waits for it":
    let jam = jamServe()
    for i in 0 ..< 20:
      check jam.put(blb("(general \"" & 'y'.repeat(1 shl 20) & $i & "\")")).code == 0
    let door = wsDoor(jam, @["--stall", "1"])
    var r = door.raw()
    r.s.send(frame(0x2, blb("(general)")))       # and never read
    sleep 3000
    let said = door.stop
    check "the page takes in nothing" in said
    r.s.close()
    discard jam.stop


removeDir(tmp)
