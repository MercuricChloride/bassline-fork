## bl-jam, run as `bl jam`: a place where people, agents and programs
## put answers and ask questions
##
## The protocol is the convention search spaces keep: (Q A) puts A as an
## answer to Q, (Q) asks Q, and a jam tells whoever asks (Q R A) for each
## answer, R its own order. `bl jam serve` is a jam; `bl jam` is a
## terminal on one; `bl jam mcp` puts an agent on one; `bl jam share`
## shares a search space on one; `bl jam keep` keeps files on one; `bl
## jam bridge` tells two jams what is said on each other; any program
## joins through `bl reach`.

import std/[options, os, strutils, sugar]
import harness, jam_client, jam_kept, jam_tui, jam_mcp, jam_share, jam_scan, jam_bridge, jam_keep
import bl/[core, queries]
import bl/lib/[bvarfile, jam, server]
import bl/queries/rewrite
import bl/lib/crypto/clave

proc serve(t: Tool, a: Args) =
  if a.positional.len > 1:
    t.misuse "takes one place at most"
  let spelled = if a.positional.len == 1: a.positional[0] else: configured("listen", JamListen)
  let place =
    try: parsePlace(spelled, allowZero = true)
    except ValueError as e: t.misuse e.msg
  if place.kind == sshPlace:
    t.misuse "a jam is local; ssh:// is for reach"
  let called = a.get("as", "jam")
  if a.has("new") and (a.has("log") or a.has("memory")):
    t.misuse "--new begins a jam among those kept in " & jamsDir() &
             "; --log and --memory say where to keep one instead"
  var path = ""
  let log =
    if a.has("memory"): spaceVar[Value, Ranked[Value]](id = sym"jam")
    else:
      if a.has("log"): path = a.get("log")
      else:
        if not fileName(called):
          t.misuse "a jam's name names its file: letters, digits, '.', '_' and '-', " &
                   "not beginning with '.'"
        path = keptAt(called)
        if a.has("new") and fileExists(path):
          fail "there is a jam called " & called & " already (bl jam list lists them); " &
               "serve it without --new"
        if a.has("as") and not a.has("new") and not fileExists(path):
          fail "no jam called " & called & " (bl jam list lists them); --new begins one"
      if path.parentDir.len > 0: createDir(path.parentDir)
      if not hold(path):
        let at = servedAt(path)
        fail "the jam kept in " & path & " is being served already" &
             (if at.isSome and at.get.kind == bText: " at " & at.get.text else: "")
      try: logVar[Value, Ranked[Value]](path, id = sym"jam")
      except CatchableError as e: fail "can't keep the jam in " & path & ": " & e.msg
  let key = if a.has("key"): some loadKeypair(a.get("key")) else: none(Keypair)
  let name = sym(called)
  var passes: seq[rewrite.Shape]
  for spelled in a.every("pass"):
    try: passes.add rewrite.Shape.fromValue(readValue(spelled))
    except ValueError as e: t.misuse "--pass takes a shape: " & e.msg
  let jam = newJam(log, signedOnly = a.has("clave"), key = key, name = name, passes = passes)
  let observe: Observer = (e: EdgeEvent) => chatter($e)
  proc offer(tell: (Value) -> bool): Line =
    let line = jam.newLine(tell)
    proc hear(v: Value): bool =
      result = jam.hear(line, v)
      if not result:
        let s = $v
        chatter "refused " & (if s.len > 72: s[0 ..< 72] & "…" else: s)
    proc quiet(): bool = jam.quiet(line)
    Line(hear: hear, quiet: quiet)
  var listener: Listener
  try:
    listener = newListener(place.port, offer, observe, place.host)
  except CatchableError as e:
    fail "can't listen on " & $place & ": " & e.msg
  let at = $Place(kind: tcpPlace, host: place.host, port: listener.port)
  chatter "listening on " & at & ", as " & called &
    (if a.has("clave"): ", taking signed values only" else: "") &
    (if key.isSome: ", stamping what it keeps under " & $initRec(@[StampsQ, name]) else: "") &
    (if passes.len > 0: ", passing through what fits " & $passes.len &
                        (if passes.len == 1: " shape" else: " shapes") else: "")
  var about = @[(sym"served", text(at)), (sym"pid", toValue(getCurrentProcessId())),
                (sym"since", toValue(now()))]
  if path.len > 0: about.add (sym"kept", text(path))
  running(initRec(@[JamQ, name, initDict(about)]))
  if path.len > 0:
    served(path, at)
    chatter "keeping what is put in " & path
  waitFor listener.serve()

let tools = [
  Tool(name: "jam", args: "[ROOM…]",
       summary: "a terminal on a jam: read and speak in its rooms",
       about: """
ROOM is a name (general) or any value in the text syntax; the default is
general, and your own room, (for NAME), is always open. Type to speak in
the room shown; tab moves between rooms, ↑↓ (the wheel too),
pgup/pgdn and m-v/c-v (half a page) scroll back, esc comes back to the
newest, and alt-return or ctrl-j breaks a line; editing keys are a
shell's. /help lists the commands:
/join ROOM, /leave, /msg NAME TEXT, /re N TEXT (answer message #N),
/say VALUE (say a value, not text), /who, /rooms, /quit. @NAME in text
says whom it is for, and @all is everyone who hears the room.

What you say waits, dim, until the jam tells it back, and is marked not
heard if it never does (a jam taking signed values only refuses what
isn't signed). A name with ✓ signed with a key it goes by. What you say
is signed with your own key, ~/.bl/key.blb (bl clave keygen makes it),
when it is there: --key signs with another, --no-sign with none.""",
       opts: speakingOpts, run: jam_tui.run),
  Tool(name: "jam serve", args: "[PLACE]",
       summary: "a jam: keep every answer put, tell whoever asks",
       about: """
PLACE is as for bl serve. The default is """ & JamListen & """, every
interface, so clients here find it at """ & JamPlace & """ and others
reach it on the network, and 127.0.0.1:8456 keeps it to this machine.
`bl config listen PLACE` makes PLACE the default instead.
Anyone who can reach it can put to it unless --clave. Over a
connection, (Q A) puts A as an answer to the question Q and (Q) asks Q.
The jam tells each line that asks Q the record (Q R A) for every answer
to Q, what it has and then each as it comes, R the order the jam heard
it in; an answer put twice is kept once. Signed values from bl clave
are taken as what they sign, and kept signed. When a line stops
speaking, or the jam can no longer reach it, the jam puts
(gone !{(by ID) (at MS)}) for each (here !{(by ID) …}) the line put and
hasn't said since is gone; a jam started on a log does so for everyone
the log says is here.

Each jam is kept by name in ~/.bl/jams/NAME.blb: --as NAME serves the
jam called NAME (default jam), and --as NAME --new begins one, so
several jams are kept, each served when it is worked on and read back
whenever (bl jam list lists them). A jam answers (jam) with which jam it
is, !{(identity NAME) (identity ID) (at MS)}, put the first time it is
served, so a client dialling its place again can tell it apart from
another jam served there since; lines may not put to it. While it is
served it holds its log locked, so it is served once, and keeps where
in NAME.at beside it.

Given --key, the jam signs its own order. It goes by its name and the
key, says so in its own (here …), and for every
answer it keeps puts the signed (stamp Q R D T PREV) under
(stamps NAME), told at R, the rank of what it stamps: D is the digest
of the answer as put, T the jam's clock in milliseconds, and PREV the
digest of the stamp before. Lines may ask (stamps NAME) and may not put
to it.

--pass SHAPE, as many times as wanted, passes through what fits: a
put whose (Q A) fits SHAPE, (shape EXAMPLE {HOLE …}), is taken and
checked as any put is, and told to each line asking Q at that moment as
(Q nil A), nil where the rank goes, and kept nowhere, so nobody asking
later is told it and it takes no rank or stamp. It suits what is too
bulky or too brief to keep: --pass '(shape ((digest a h) v) {a h v})'
passes file content, which keepers (bl jam keep) hold instead. Asked
(passes), the jam tells each shape it passes as (passes nil SHAPE), and
lines may not put to it.

What is put is kept in the log, a bare concatenation of the records, so
`bl cat ~/.bl/jams/NAME.blb` reads it, and a jam started on it again
holds what it held.""",
       opts: @[Opt(long: "as", arg: "NAME",
                   help: "the jam to serve, and the name it goes by (default jam)"),
               Opt(long: "new", help: "begin a jam called NAME, kept with the rest"),
               Opt(long: "log", arg: "PATH",
                   help: "keep it in PATH instead of ~/.bl/jams/NAME.blb"),
               Opt(long: "memory", help: "keep nothing past this run"),
               Opt(long: "clave", help: "take only values signed with bl clave " &
                                        "whose signatures hold"),
               Opt(long: "key", arg: "PATH", help: "sign the jam's order with this keypair"),
               Opt(long: "pass", arg: "SHAPE",
                   help: "tell what fits SHAPE and don't keep it, as many times as wanted")],
       run: serve),
  Tool(name: "jam bridge", args: "PLACE [PLACE]",
       summary: "two jams, each told what is said on the other",
       about: """
Keeps a line to each jam and puts on each what the other tells it, so
whoever is on either hears what is said on both. Given one PLACE, the
other is the jam this machine's clients use (--at, else $JAM_AT, else
the config's at, else """ & JamPlace & """), and a PLACE may be a
name from bl name. It asks both who is here and who has gone, which rooms
there are, every room either lists, the own room of everyone either has
heard from, every question a message it carries says it wants (a record
(want Q) in the message, as a keeper says what it lacks), each question
--ask names, and every question a jam with a key has stamped. An answer goes as it was put: one that came signed goes
as it was signed, so either jam takes it as its speaker's and a reader
on either can check it, and anything else as (Q A), unsigned unless
--sign. A jam keeps an answer once, and nothing a jam has told the
bridge, or the bridge has put on it, is put on it again, so a value
said on one jam reaches every jam bridged to it and stops. Which jam
each is, and its stamps, stay its own.

When either jam can't be reached the bridge hangs up on the other too,
so that jam says whoever came across the bridge is gone, and it dials
both again every two seconds. Whoever is still here hears they were
called gone and says they are here again, and the bridge brings that
across. It asks signed when there is a key (your own,
~/.bl/key.blb, unless --key or --no-sign), so a jam taking signed values
only answers it. What came unsigned such a jam takes only with --sign,
as the bridge's word.""",
       opts: @[speakingOpts[0],
               Opt(long: "ask", arg: "Q",
                   help: "ask both this question too (a name or any value), as many times as wanted"),
               Opt(long: "key", arg: "PATH", help: "ask, and with --sign put, signed with this keypair"),
               Opt(long: "sign", help: "sign what came unsigned, with --key or ~/.bl/key.blb"),
               Opt(long: "no-sign", help: "ask unsigned")],
       run: jam_bridge.run),
  Tool(name: "jam list", args: "",
       summary: "the jams kept on this machine, and what each holds",
       about: """
One value for each jam kept in ~/.bl/jams, by name:
(jam NAME {kept: PATH records: N rooms: {ROOM …} who: {NAME …}
began: MS last: MS served: PLACE}). rooms are those listed under
(rooms …), who those who said they were here, began and last the
earliest and latest `at` its answers carry, and served where it is
served now, if it is. `bl jam list | bl cat` reads it; `bl jam serve
--as NAME` serves one.""",
       opts: @[], run: jam_kept.list),
  Tool(name: "jam running", args: "",
       summary: "the jams served and the bridges running on this machine",
       about: """
One value for each, whether it keeps what is put or not:
(jam NAME {served: PLACE pid: N since: MS kept: PATH}) for a jam, kept
only when it keeps a log, and (bridge {ends: [PLACE PLACE] pid: N
since: MS}) for a bridge. Each says so in ~/.bl/running/PID.blb, held
while it runs, so what has gone isn't listed, however it went.
`bl jam running | bl cat` reads it, and bl jam stop stops one.""",
       opts: @[], run: jam_kept.listRunning),
  Tool(name: "jam stop", args: "[WHAT…]",
       summary: "stops jams and bridges running on this machine",
       about: """
WHAT is a pid, a jam's name, the port it is served on as :PORT or
HOST:PORT, or bridge for every bridge, as bl jam running lists them.
Each is stopped, and said to be once it has gone; WHAT that names
nothing running exits 1. --all stops everything running here.""",
       opts: @[Opt(long: "all", help: "stop every jam and bridge running here")],
       run: jam_kept.stop),
  Tool(name: "jam scan", args: "[PORT…]",
       summary: "the places on this machine's networks that answer, and what each jam says it is",
       about: """
Tries every address on each network this machine is on, its own among
them, on each PORT (default 8455 and 8456). A network wider than /24 is
looked at only in the /24 around this machine's address on it; --net
names networks instead, A.B.C.D/N or one address, as many times as
wanted. Where a connection is taken it is asked (jam), signed as bl jam
signs (your own key, ~/.bl/key.blb, when it is there), and the place is
written as (found "HOST:PORT"), with the first value said back when one
comes within --wait ms: a jam tells (jam R !{(identity NAME) …}).
--silent only connects, and asks nothing: a place that isn't a jam, bl
serve's among them, hears the ask as one more value. `bl jam scan |
bl cat` reads what was found, and bl name names a place.""",
       opts: @[Opt(long: "net", arg: "A.B.C.D/N",
                   help: "a network to look on instead of this machine's own"),
               Opt(long: "wait", arg: "MS",
                   help: "how long a place is given to connect, and to answer (default 500)"),
               Opt(long: "silent", help: "only connect: ask nothing"),
               Opt(long: "key", arg: "PATH", help: "sign the ask with this keypair"),
               Opt(long: "no-sign", help: "ask unsigned")],
       run: jam_scan.run),
  Tool(name: "jam mcp", args: "[ROOM…]",
       summary: "jams as tools for an agent, over MCP on stdio",
       about: """
For Claude Code and other MCP clients: two tools in values, tell, which
hands the jam values exactly as written ((Q A) puts, (Q) asks), and
heard, which searches what the jam has told it as (heard Q R READINGS A)
records. An agent may be on several jams at once: jams lists them and,
with scan, finds what answers on this machine's networks as bl jam scan
does, join puts it on one, leave takes it off, and tell and heard take
jam to say which. --at given more than once starts it on each.
--push claude (default) pushes what is said to the agent as a
claude/channel notification once the MCP client is initialized;
--push none gives tool-only delivery, with no channel notifications.
The agent goes by --as, or $JAM_NAME, or claude-XXXX.
ROOM is where it starts (default general). --hear all pushes everything
said in its rooms, not only what is said to it.""",
       opts: speakingOpts & @[Opt(long: "hear", arg: "WHAT",
                                  help: "mine (default) or all"),
                              Opt(long: "push", arg: "MODE",
                                  help: "claude (default) or none (tools only)")],
       run: jam_mcp.run),
  Tool(name: "jam share", args: "SPACE [ROOM…]",
       summary: "a search space shared on a jam, by a speaker saying what it finds",
       about: """
SPACE is a search space written down, as Search.fromValue reads one: a
file of CE or the textual syntax. It is put under its digest,
(DIGEST SPACE), and the digest under `knowledge`, so a program asks the
jam (knowledge), then the digest, and reads the space into a search of
its own. The speaker (--as, or $JAM_NAME, or kb) hears its own room and
ROOM… (default general). What a message there says to it, in its own
room or naming it, is asked of the space, and what it finds is said in
that room as (found QUERY {ANSWER …}), re the message and for whoever
said it; past 200 answers, every answer is also put as
((found QUERY) ANSWER). Messages to it from while it was away are taken
up when it comes back, unless it has already said something re them.
Whoever comes onto the jam after it is told once, in their own room,
what it shares and how to ask, as (sharing DIGEST TEXT), and the first
ROOM hears the same once; the space's answers to `help` say how to ask
it. What a share says, found and sharing values, is passed over.""",
       opts: speakingOpts, run: jam_share.run),
  Tool(name: "jam keep", args: "[ROOM…]",
       summary: "a keeper on a jam: files held by digest, put where someone wants them",
       about: """
Holds a keep, values filed under their digests (bl/lib/fs: a file's
bytes, a manifest (chunks SIZE [D …]) and its (chunk BYTES), a
(tree {NAME: ENTRY …})), in --keep PATH, ~/.bl/fs/keep.blb by default,
and hears its own room and ROOM… (default fs). A message there saying
(want D) for each digest someone lacks is taken up when the keeper holds
some of them and hasn't been told the jam answers them: it asks the jam
each and says (has D) for each, re the want, and once that is told back
puts (D V) for each D the jam hasn't answered and no earlier (has D) re
the same want names, so the first keeper to say has, in the jam's
order, puts it. A message saying (keep D) has it fetch D and everything
under it: it asks the jam, says (want D) re the keep for what it lacks,
stores each answer that checks against its digest, and says (kept D) re
the keep once it holds all of it. A want or keep for someone else is
left to them. What was said to it while it was away is taken up when it
comes back, unless it has said something re it, or someone has said has
re a want. It goes by --as, or $JAM_NAME, or keeper, and signs with your
own key, ~/.bl/key.blb, when it is there.""",
       opts: speakingOpts & @[Opt(long: "keep", arg: "PATH",
                                  help: "the keep (default ~/.bl/fs/keep.blb)")],
       run: jam_keep.run)]

proc usage(): string =
  result = "usage: bl jam [COMMAND] [ARGS…]\n\n" &
    "rooms where people, agents and programs talk\n\n"
  result.add "  " & "(none)".pad(8) & "  " & tools[0].summary & "\n"
  for t in tools[1 .. ^1]:
    result.add "  " & t.name.split(' ')[1].pad(8) & "  " & t.summary & "\n"
  result.add "\n`bl jam COMMAND --help` says more about each.\n"

proc main() =
  let argv = commandLineParams()
  if argv.len > 0 and argv[0] in ["-h", "--help"]:
    say usage()
    return
  for t in tools[1 .. ^1]:
    if argv.len > 0 and t.name == "jam " & argv[0]:
      t.start(argv[1 .. ^1])
      return
  tools[0].start(argv)

when isMainModule:
  main()
