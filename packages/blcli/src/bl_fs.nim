## bl-fs, run as `bl fs`: files as values, by their content and by name
##
## Files go into a keep (bl/lib/fs), values filed under their digests,
## ~/.bl/fs/keep.blb by default, the keep `bl jam keep` serves. A name is
## an alias (bl/lib/fsnames), someone's signed word on a jam that it
## names some content or a tree; what a name names to you is what the
## keys you trust said, the newest first.
##
## What the keep lacks is asked of the jam, and wanted in fs, where a
## keeper that holds it puts it. Whatever the jam tells that checks
## against its digest is kept, so what was fetched once is there next
## time.

import std/[options, os, sequtils, sets, strutils, sugar]
from std/times import epochTime
import harness, jam_client
import bl/[core, queries]
import bl/lib/[fs, fsnames, jam]
import bl/lib/crypto/clave

const DefaultWait = 30  ## seconds to wait with nothing new coming

let WantQ = sym"want"

type Fs = ref object
  t: Tool
  speaker: Speaker
  place: Place
  room: Value             ## where wants are said
  keep: Keep
  content: Search[Value, Value]
  trusts: (Key) -> bool
  wait: float             ## seconds without anything new before giving up
  c: Client               ## the line to the jam, once one is needed
  asked: HashSet[Value]   ## digests asked of the jam
  told: Option[Value]     ## an answer it put, until the jam tells it back
  back: bool              ## whether the jam has told it back
  rank: int               ## where the jam heard it, or Passed

proc defaultKeep(): string = getHomeDir() / ".bl" / "fs" / "keep.blb"

proc keyArg(t: Tool, s: string): Key =
  ## a key spelled as its 32 bytes, 0x…
  let v = try: readValue(s) except ReadError: t.misuse s & " isn't a key: 32 bytes, 0x…"
  if not v.isKind(bBytes, unmarked) or v.bytes.len != 32:
    t.misuse s & " isn't a key: 32 bytes, 0x…"
  for i, b in v.bytes: result[i] = b

proc open(t: Tool, a: Args): Fs =
  let path = a.get("keep", defaultKeep())
  let keep = try: openKeep(path) except CatchableError as e: fail "can't keep in " & path & ": " & e.msg
  result = Fs(t: t, speaker: t.speakerFrom(a, signs = true), place: t.placeFrom(a),
              room: readValue(a.get("room", "fs")), keep: keep, content: keepSearch(keep),
              wait: t.intOpt(a, "wait", DefaultWait).float, rank: -1)
  if a.has("anyone"):
    result.trusts = (k: Key) => true
  else:
    var keys = a.every("trust").mapIt(t.keyArg(it))
    for v in configured(sym"trust"):
      if v.isKind(bBytes, unmarked) and v.bytes.len == 32: keys.add t.keyArg($v)
    if result.speaker.key.isSome: keys.add result.speaker.key.get.pubkey
    result.trusts = trusting(keys)

proc heard(f: Fs, h: Heard) =
  if h.q in f.asked:
    if verifies(h.q, h.said): discard f.keep.store(h.said)
  elif f.told.isSome and h.answer == f.told.get:
    (f.back, f.rank) = (true, h.rank)

proc line(f: Fs): Client =
  ## the line to the jam, dialled the first time it is needed
  if f.c == nil:
    f.c = try: dial(f.place, f.speaker)
          except CatchableError as e: fail "no jam at " & $f.place & ": " & e.msg
    f.c.onHeard = (h: Heard) => f.heard(h)
  f.c

proc close(f: Fs) =
  if f.c != nil and not f.c.closed: f.c.bye()
  f.keep.close()

proc putAndWait(f: Fs, q, a: Value): int =
  ## puts `a` as an answer to `q`, answering the rank the jam tells it
  ## back at, or Passed when the jam passed it on and kept nothing:
  ## either way, once it is told back the jam has told everything asked
  ## before it
  let c = f.line
  c.ask q
  f.back = false
  f.told = some c.put(q, a)
  let until = epochTime() + f.wait
  while not f.back:
    if c.closed: fail "the jam at " & $f.place & " went away"
    if epochTime() > until: fail "the jam at " & $f.place & " didn't tell back what was put"
    turn(20)
  f.told = none(Value)
  f.rank

proc putAlias(f: Fs, name, d: Value) =
  ## puts the signed alias, and the name under (aliases), saying where
  ## the jam keeps the alias. One the jam passes on is heard only by
  ## whoever asks for it now, so it names nothing to anyone later
  if f.speaker.key.isNone: fail "an alias is signed, and there is no key (bl clave keygen makes one)"
  let r = f.putAndWait(aliasQ(name), d)
  emit initRec(@[sym"put", aliasQ(name), if r < 0: null() else: toValue(r)])
  if r < 0: fail "the jam at " & $f.place & " passed the alias on and kept nothing"
  discard f.line.put(AliasesQ, name)

proc caughtUp(f: Fs) =
  ## everything asked so far has been told: a here put after it is told back
  discard f.putAndWait(HereQ, f.speaker.here)

proc fetch(f: Fs, lacks: () -> seq[Value]): seq[Value] =
  ## asks the jam for what `lacks` says is lacking, and wants it in the
  ## room, until nothing is lacking or nothing new has come for a while;
  ## answers what is lacking still
  result = lacks()
  if result.len == 0: return
  let c = f.line
  var (was, since) = (initHashSet[Value](), epochTime())
  while result.len > 0:
    let lacking = result.toHashSet
    if lacking != was: (was, since) = (lacking, epochTime())
    elif epochTime() - since > f.wait or c.closed: return
    let fresh = result.filterIt(it notin f.asked)
    if fresh.len > 0:
      for d in fresh:
        f.asked.incl d
        c.ask d
      discard c.put(f.room, obj(@[initRec(@[ByQ, f.speaker.by]), initRec(@[AtQ, toValue(now())]),
        initRec(@[SaidQ, text($f.speaker.name & " wants " & $fresh.len)])] &
        fresh.mapIt(initRec(@[WantQ, it]))))
    turn(50)
    result = lacks()

proc lackingFail(f: Fs, lacking: seq[Value]) {.noreturn.} =
  for d in lacking: chatter "lacking " & $d
  fail "nobody gave " & $lacking.len & " of what was wanted in " & $f.wait.int & "s; " &
       "a keeper holding it (bl jam keep) puts it when it hears the want"

# ================ what an argument names ================

proc split(f: Fs, what: string): tuple[root: Value, path: seq[string]] =
  ## NAME/a/b, or (digest blake2b 0x…)/a/b
  var rest: string
  if what.startsWith("("):
    let close = what.find(')')
    if close < 0: f.t.misuse what & " begins a digest it doesn't end"
    result.root = try: readValue(what[0 .. close])
                  except ReadError as e: f.t.misuse what & ": " & e.msg
    if not Digest.fits(result.root): f.t.misuse what[0 .. close] & " isn't a digest"
    rest = what[close + 1 .. ^1]
  else:
    let slash = what.find('/')
    let name = if slash < 0: what else: what[0 ..< slash]
    if name.len == 0: f.t.misuse what & " names nothing before its path"
    result.root = text(name)
    rest = if slash < 0: "" else: what[slash + 1 .. ^1]
  result.path = rest.split('/').filterIt(it.len > 0)

proc named(f: Fs, name: Value): seq[Value] =
  ## the digests `name` names to whoever runs this, newest first
  discard f.line
  f.c.ask aliasQ(name)
  f.caughtUp()
  f.c.local.names(f.trusts)[name].toSeq

proc entries(f: Fs, what: string, all = false): seq[Value] =
  ## the entries `what` names: from the first digest whose path can be
  ## walked, or from every one when `all`
  let (root, path) = f.split(what)
  let roots = if Digest.fits(root): @[root] else: f.named(root)
  if roots.len == 0:
    fail "nothing names " & root.text & " to you (bl fs alias " & root.text &
         " --anyone says who has named it)"
  for each in roots:
    let d = each
    let lacking = f.fetch(() => f.content.lacking(d, path))
    if lacking.len > 0: f.lackingFail(lacking)
    let found = f.content.walk(d, path).toSeq
    result.add found
    if found.len > 0 and not all: return
  if result.len == 0:
    fail what & " names nothing" & (if roots.len > 1: " from any of the " & $roots.len &
                                                      " digests " & $root & " names" else: "")

proc contentOf(entry: Value): Option[Value] =
  ## what an entry's content is filed under: a file's, a directory's
  ## tree, or a bare digest
  if Digest.fits(entry): some(entry) else: named(entry)

# ================ the commands ================

proc add(t: Tool, a: Args) =
  if a.positional.len == 0: t.misuse "takes what to add"
  if a.has("alias") and a.positional.len > 1: t.misuse "--alias names one thing added"
  let f = t.open(a)
  defer: f.close()
  for path in a.positional:
    let entry = try: f.keep.add(path, (p, why: string) => chatter("skipped " & p & ": " & why))
                except CatchableError as e: fail "can't add " & path & ": " & e.msg
    let d = contentOf(entry)
    emit initRec(@[sym"added", text(path), d.get(entry)])
    if a.has("alias"):
      if d.isNone: fail path & " is a link, which names a path, not content"
      f.putAlias(text(a.get("alias")), d.get)

proc alias(t: Tool, a: Args) =
  if a.positional.len notin 1 .. 2: t.misuse "takes a name, and what it names"
  let f = t.open(a)
  defer: f.close()
  let name = text(a.positional[0])
  if a.positional.len == 1:
    discard f.named(name)
    for al in f.c.local.aliasesOf(name):
      if f.trusts(al.signer):
        emit initRec(@[AliasHead, name, al.digest, bytes(@(al.signer))])
    return
  let given = try: valueArg(a.positional[1]) except ValueError as e: t.misuse e.msg
  let d = if Digest.fits(given): some(given)
          elif given.isKind(bRec) and given.items.len == 3 and given.head == sym"added": contentOf(given.items[2])
          else: named(given)
  if d.isNone: t.misuse a.positional[1] & " is neither a digest nor an entry naming one"
  f.putAlias(name, d.get)

proc ls(t: Tool, a: Args) =
  if a.positional.len != 1: t.misuse "takes what to list"
  let f = t.open(a)
  defer: f.close()
  for entry in f.entries(a.positional[0], all = a.has("all")):
    let d = if FileEntry.fits(entry) or LinkEntry.fits(entry): none(Value) else: contentOf(entry)
    if d.isSome:
      let lacking = f.fetch(() => (if f.content.answerOf(d.get).isNone: @[d.get] else: @[]))
      if lacking.len > 0: f.lackingFail(lacking)
    let listed = f.content.listing(entry)
    if listed.isSome:
      for (name, e) in listed.get: emit initRec(@[sym"entry", text(name), e])
    else:
      let (root, path) = f.split(a.positional[0])
      emit initRec(@[sym"entry", (if path.len > 0: text(path[^1]) else: root), entry])

proc cat(t: Tool, a: Args) =
  if a.positional.len != 1: t.misuse "takes the file to write out"
  let f = t.open(a)
  defer: f.close()
  let entry = f.entries(a.positional[0])[0]
  if LinkEntry.fits(entry) or DirEntry.fits(entry):
    fail a.positional[0] & " is a " & (if DirEntry.fits(entry): "directory (bl fs ls lists it)"
                                       else: "link")
  let d = contentOf(entry).get
  let first = f.fetch(() => (if f.content.answerOf(d).isNone: @[d] else: @[]))
  if first.len > 0: f.lackingFail(first)
  if FsTree.fits(f.content.answerOf(d).get):
    fail a.positional[0] & " is a directory (bl fs ls lists it)"
  let lacking = f.fetch(() => f.content.missing(d))
  if lacking.len > 0: f.lackingFail(lacking)
  let data = f.content.bytesOf(d)
  if data.isNone: fail a.positional[0] & " isn't a file's content"
  emit data.get

proc get(t: Tool, a: Args) =
  if a.positional.len != 2: t.misuse "takes what to get and where to write it"
  let dest = a.positional[1]
  if fileExists(dest) or dirExists(dest) or symlinkExists(dest): fail dest & " is there already"
  let f = t.open(a)
  defer: f.close()
  let entry = f.entries(a.positional[0])[0]
  let d = contentOf(entry)
  if d.isSome:
    let lacking = f.fetch(() => f.content.missing(d.get))
    if lacking.len > 0: f.lackingFail(lacking)
  try: f.content.writeOut(entry, dest)
  except CatchableError as e: fail "can't write " & dest & ": " & e.msg
  emit initRec(@[sym"got", text(a.positional[0]), text(dest), entry])

# ================ usage ================

let
  keepOpt = Opt(long: "keep", arg: "PATH", help: "the keep (default ~/.bl/fs/keep.blb)")
  readingOpts = speakingOpts & @[keepOpt,
    Opt(long: "trust", arg: "KEY", help: "take aliases this key signs (0x…), as many times as wanted"),
    Opt(long: "anyone", help: "take aliases whoever signs them"),
    Opt(long: "room", arg: "ROOM", help: "where to say what is wanted (default fs)"),
    Opt(long: "wait", arg: "S", help: "seconds to wait with nothing new coming (default " &
                                     $DefaultWait & ")")]
  whatIs = """
WHAT is a name and a path, NAME/a/b, or a digest and a path,
'(digest blake2b 0x…)/a/b'. A name names what aliases signed by keys
you trust say, the newest first: your own key, ~/.bl/key.blb, each
--trust KEY and each (trust KEY) in your config (bl config trust KEY
--add), or anyone's with --anyone. What the keep lacks is asked of the
jam and wanted in fs as (want D), where a keeper (bl jam keep) that
holds it puts it; what comes and checks is kept."""

let tools = [
  Tool(name: "fs add", args: "PATH…",
       summary: "files and directories into the keep, by their content",
       about: """
Each PATH and everything under it is filed in the keep under its
digest, and said as (added PATH D), D the content's digest or a
directory's tree's. A file of 64KB or less is its bytes, a larger one a
manifest of chunks cut where its content says, so the same bytes are
filed once wherever they come from. --alias NAME also puts the signed
alias ((alias NAME) D) on the jam, and NAME under (aliases), and says
(put (alias NAME) R). Nothing goes on the jam otherwise: a keeper on
the keep (bl jam keep) puts what someone wants.""",
       opts: readingOpts & @[Opt(long: "alias", arg: "NAME", help: "name what is added, on the jam")],
       run: add),
  Tool(name: "fs alias", args: "NAME [D]",
       summary: "names content on the jam, or says what a name names",
       about: """
With D, a digest or an entry naming one, puts ((alias NAME) D) signed
with your key, and NAME under (aliases), and says (put (alias NAME) R)
once the jam tells it back. Anyone may name anything, and nobody's
alias is the alias: each reader takes those signed by keys it trusts.
Without D, says what NAME names to you as (alias NAME D KEY), the
newest first: with --anyone, whoever signed it.""",
       opts: readingOpts, run: alias),
  Tool(name: "fs ls", args: "WHAT",
       summary: "the names in a directory",
       about: "Says (entry NAME ENTRY) for each name in the directory WHAT names, ENTRY " &
              "(file D SIZE MODE), (dir D MODE) or (link TARGET); --all lists every " &
              "answer a name gives, not only the newest that walks.\n\n" & whatIs,
       opts: readingOpts & @[Opt(long: "all", help: "every answer, not the newest that walks")],
       run: ls),
  Tool(name: "fs cat", args: "WHAT",
       summary: "a file's bytes, on stdout",
       about: whatIs, opts: readingOpts, run: cat),
  Tool(name: "fs get", args: "WHAT DEST",
       summary: "a file or directory written out at DEST",
       about: "Writes what WHAT names at DEST, which must not be there, and says " &
              "(got WHAT DEST ENTRY).\n\n" & whatIs,
       opts: readingOpts, run: get)]

proc usage(): string =
  result = "usage: bl fs COMMAND [ARGS…]\n\nfiles as values, by their content and by name\n\n"
  for t in tools:
    result.add "  " & t.name.split(' ')[1].pad(6) & "  " & t.summary & "\n"
  result.add "\n`bl fs COMMAND --help` says more about each.\n"

proc main() =
  let argv = commandLineParams()
  if argv.len == 0 or argv[0] in ["-h", "--help"]:
    say usage()
    if argv.len == 0: quit 2
    return
  for t in tools:
    if t.name == "fs " & argv[0]:
      t.start(argv[1 .. ^1])
      return
  chatter "bl fs: no command " & argv[0]
  toStderr "\n" & usage()
  quit 2

when isMainModule:
  main()
