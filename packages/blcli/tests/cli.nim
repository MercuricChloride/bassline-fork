## What the bl toolkit's tests share: the built binaries in ../bin, run
## through a shell or as live child processes, against the shared corpus
## and against fakes placed first on PATH; a listener alongside, a place
## that speaks, and a jam with agents on it. Each tests/t*.nim imports it.

import std/[algorithm, exitprocs, json, net, options, os, osproc, posix, sequtils, streams,
            strtabs, strutils, unittest]
import bl/core
from bl/queries import answer, knownAs
import bl/lib/crypto/digest
from bl/lib/jam import heard, vouched
from bl/lib/crypto/clave import Keypair, fromValue
from std/unicode import runeLen
export algorithm, json, net, options, os, osproc, posix, sequtils, streams, strtabs, strutils,
       unittest, core, answer, knownAs, digest, heard, vouched, Keypair, fromValue, runeLen

let
  here* = currentSourcePath().parentDir
  bin* = here.parentDir / "bin"
  corpusPath* = here.parentDir.parentDir.parentDir / "corpus" / "corpus.blb"
  corpus* = readFile(corpusPath)
  corpusCount* = block:
    var n = 0
    for _ in ValueView.decode(corpus.toOpenArrayByte(0, corpus.high)): inc n
    n
  tmp* = getTempDir() / ("blcli-" & $getpid())
  fakes* = tmp / "fakes"

doAssert fileExists(bin / "bl") and fileExists(bin / "bl-clave") and
  fileExists(bin / "bl-jam"),
  "build first: nim build"
createDir(fakes)
putEnv("PATH", fakes & ":" & bin & ":" & getEnv("PATH"))
# a home of the tests' own, so nothing in the person's ~/.bl (a config, a
# key, the jams kept) reaches them; a test wanting another says so
createDir(tmp / "home")
putEnv("HOME", tmp / "home")

proc fake*(name, script: string, executable = true) =
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

type Ran* = tuple[output, errors: string, code: int]

var runs = 0
proc sh*(cmd: string, input = ""): Ran =
  ## `cmd` through sh, `input` on its stdin
  inc runs
  let base = tmp / ("run" & $runs)
  writeFile(base & ".in", input)
  let code = execCmd("(" & cmd & ") < " & quoteShell(base & ".in") & " > " &
                     quoteShell(base & ".out") & " 2> " &
                     quoteShell(base & ".err"))
  (readFile(base & ".out"), readFile(base & ".err"), code)

proc blb*(text: string): string =
  ## the CE of the values `text` spells
  for v in readDocument(text):
    result.add v.ce.toString

proc decoded*(ce: string): seq[Value] =
  ## the values CE bytes spell
  for v in Value.decode(ce.toOpenArrayByte(0, ce.high)):
    result.add v

proc file*(name, content: string): string =
  result = tmp / name
  writeFile(result, content)

proc readFor*(fd: cint, want: int, ms = 5000): string =
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

type Serving* = object
  p*: Process
  place*: string

proc serve*(place: string, extra: seq[string] = @[]): Serving =
  ## `bl serve PLACE`, once it says where it listens
  result.p = startProcess(bin / "bl", args = @["serve", place] & extra,
                          options = {})
  let said = result.p.errorStream.readLine
  doAssert said.startsWith("-- listening on "), said
  result.place = said["-- listening on ".len .. ^1]

proc port*(s: Serving): string =
  s.place[s.place.rfind(':') + 1 .. ^1]

proc arrived*(s: Serving, want: int): string =
  ## what it has written of the values that arrived, up to `want` bytes
  readFor(cint(s.p.outputHandle), want)

proc stop*(s: Serving): string =
  ## its chatter, once it has gone
  discard kill(Pid(s.p.processID), SIGTERM)
  discard s.p.waitForExit
  result = s.p.errorStream.readAll
  s.p.close

# ================ a place that speaks ================

type Peer* = object
  server*: Socket
  port*: int

proc peer*(): Peer =
  result.server = newSocket(buffered = false)
  result.server.setSockOpt(OptReuseAddr, true)
  result.server.bindAddr(Port(0), "127.0.0.1")
  result.server.listen()
  result.port = int(result.server.getLocalAddr()[1])

proc talk*(p: Peer, says: string): string =
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

proc chattyPeer*(ratio: int): tuple[port: int, pid: Pid] =
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


# ================ jam ================

proc withEnv*(vars: openArray[(string, string)]): StringTableRef =
  ## this process's environment, and `vars`
  result = newStringTable()
  for k, v in envPairs(): result[k] = v
  for (k, v) in vars: result[k] = v

proc jamServe*(extra: seq[string] = @["--memory"], at = ":0", home = ""): Serving =
  ## `bl jam serve AT`, once it says where it listens, with `home` as
  ## its HOME if given
  result.p = startProcess(bin / "bl-jam", args = @["serve", at] & extra,
                          env = (if home.len > 0: withEnv({"HOME": home}) else: nil),
                          options = {})
  let said = result.p.errorStream.readLine
  doAssert said.startsWith("-- listening on "), said
  result.place = said["-- listening on ".len .. ^1].split(',')[0]

proc asking*(s: Serving, says: string): Socket =
  ## a line to the jam that has said `says`, held open to hear on
  result = newSocket(buffered = false)
  result.connect("127.0.0.1", Port(parseInt(s.port)))
  result.send(says)

proc told*(line: Socket): seq[Value] =
  ## what the jam has told the line so far
  decoded(readFor(cint(line.getFd), 1 shl 20, 400))

proc put*(s: Serving, says: string): Ran =
  sh("bl reach --source :" & s.port, says)

proc share*(s: Serving, space: string): Process =
  ## `bl jam share SPACE` as kb, on the jam `s`
  startProcess(bin / "bl-jam", args = ["share", space, "--at", ":" & s.port,
                                       "--as", "kb"], options = {})

proc stopShare*(p: Process) =
  discard kill(Pid(p.processID), SIGTERM)
  discard p.waitForExit
  p.close()

type Agent* = object
  ## `bl jam mcp` as an agent's session drives it
  p*: Process
  pending*: string
  initialization*: JsonNode
  lastResult*: JsonNode

proc tell*(a: var Agent, j: JsonNode) =
  a.p.inputStream.write($j & "\n")
  a.p.inputStream.flush()

proc next*(a: var Agent, ms = 5000): JsonNode =
  ## what it says next, or null once it says nothing for `ms`
  while '\n' notin a.pending:
    let got = readFor(cint(a.p.outputHandle), 65536, ms)
    if got.len == 0: return newJNull()
    a.pending.add got
  let nl = a.pending.find('\n')
  result = parseJson(a.pending[0 ..< nl])
  a.pending = a.pending[nl + 1 .. ^1]

proc call*(a: var Agent, id: int, tool: string, args: JsonNode): string =
  ## what a tool answers, passing over what is pushed meanwhile
  a.tell %*{"jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": {"name": tool, "arguments": args}}
  var j = a.next()
  while j.kind != JNull and j{"id"}.getInt(-1) != id: j = a.next()
  a.lastResult = j{"result"}
  a.lastResult{"content"}[0]["text"].getStr

proc pushed*(a: var Agent, ms = 1500): seq[JsonNode] =
  ## what it pushes as a channel until it pushes nothing for `ms`
  var j = a.next(ms)
  while j.kind != JNull:
    if j{"method"}.getStr == "notifications/claude/channel": result.add j
    j = a.next(ms)

proc said*(pushes: seq[JsonNode]): seq[string] =
  pushes.mapIt(it["params"]["content"].getStr)

proc begun*(p: Process, ready = true): Agent =
  ## an MCP server once it has begun
  result.p = p
  result.tell %*{"jsonrpc": "2.0", "id": 0, "method": "initialize",
                 "params": {"protocolVersion": "2025-06-18"}}
  var j = result.next()
  doAssert j{"id"}.getInt(-1) == 0, "initialize must be answered before channel notifications"
  result.initialization = j{"result"}
  if ready: result.tell %*{"jsonrpc": "2.0", "method": "notifications/initialized"}

proc agent*(s: Serving, name: string, extra: seq[string] = @[], ready = true): Agent =
  ## `bl jam mcp` as `name` on the jam `s`, once it has begun
  begun(startProcess(bin / "bl-jam", args = @["mcp", "--at", ":" & s.port,
                                             "--as", name] & extra, options = {}), ready)

proc leave*(a: var Agent) =
  ## its session ends
  a.p.inputStream.close()
  discard a.p.waitForExit(5000)
  a.p.close()

proc saidBy*(vs: seq[Value], room: Value, by = sym"kb"): seq[Value] =
  ## what `by` said in `room`, of the records the jam told
  for v in vs:
    if v.items[0] == room and v.items[2].answer(sym"by") == some by:
      result.add v.items[2].answer(sym"said").get

proc hearUntil*(line: Socket, heard: var seq[Value],
               enough: proc(vs: seq[Value]): bool, rounds = 25) =
  ## what the jam tells the line, added to `heard` until it is enough
  for _ in 0 ..< rounds:
    if enough(heard): return
    heard.add line.told


addExitProc(proc() = removeDir(tmp))
