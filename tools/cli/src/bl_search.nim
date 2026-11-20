## bl search: ask a search about the values on stdin, write its answers

import std/[options, strutils]
import harness
import bl/queries

type Builtin = object
  ## a search this bl has: what its query is, what it does, and asking it
  name: string
  query: string   ## the query's values, for the synopsis; "" for none
  arity: int      ## how many query values it takes
  summary: string
  about: string   ## whether it answers from all the values or each in turn
  ask: proc(query: seq[Value]): Search[Value, Value] {.nimcall.}
  run: proc(query: seq[Value], take: int) {.nimcall.}
    ## in place of lifting `ask`, for a search that keeps what arrives

proc under(query: seq[Value]): Search[Value, Value] =
  ## each value that `query[0]` prefixes: the value whose CE, stopped
  ## early and its open frames closed, is the prefix
  let prefix = query[0]
  newSearch[Value, Value](v => (if prefix.prefixes(v): just(v) else: empty(Value)))

proc findOver(query: seq[Value], take: int) =
  ## the find `query[0]` over what arrives on stdin. Each value is sent to a
  ## place, where it is known by its identities for the find's names to
  ## find; with no (of …) the find asks every object there and a space
  ## holding every (Q A) record there. The find is asked again as
  ## each value arrives, and each answer is written once: once per binding,
  ## or once outright under distinct or count. Refuses what isn't a find
  let fd = Find.fromValue(query[0])
  let base = query[0]
  var known = initSet()
  var records = initSet()
  proc tell(v: Value): bool =
    if v.isObject: known.incl v
    elif v.isKind(bRec, unmarked) and v.len == 2: records.incl v
    true
  let resolve = newSearch[Value, Value](n => known.members.filters(sharesIdentity(it, n)))
  proc asking(): Value =
    ## the find as it is asked now: given what is known, when it names nothing
    if fd.subjects.len > 0: return base
    var asked = base.copy
    for k in known.members: asked.incl initRec(@[ofQ, k])
    asked.incl initRec(@[ofQ, describe([searchSpace], sym"stdin",
                                       initRec(@[holdsQ, records.copy]))])
    asked
  var written = initSet()
  var taken = 0
  if take == 0: return
  proc arrived(v: Value) =
    discard tell(v)
    try:
      for r in rows(asking(), resolve = resolve):
        let key = if fd.counting or fd.once: r.answer
                  else: initRec(@[r.bindings, r.answer])
        if key in written.els: continue
        written.incl key
        emit r.answer
        inc taken
        if taken == take: quit 0
    except ValueError as e:
      fail "bl search find: " & e.msg
  stdinSource().eachValue arrived

proc walk(query: seq[Value]): Search[Value, Value] =
  ## each value, then everything inside it, depth first
  newSearch[Value, Value](v => v.walk)

const builtins = [
  Builtin(name: "under", query: "PREFIX", arity: 1, ask: under,
          summary: "every value on stdin that PREFIX selects (a record " &
                   "head, say)",
          about: "Answers from all the values on stdin, as they arrive."),
  Builtin(name: "find", query: "FIND", arity: 1, run: findOver,
          summary: "the answers of a find, its names found among the " &
                   "values on stdin",
          about: "Answers from all the values on stdin, as they arrive: " &
                 "each is known by its identities, for the find's " &
                 "(of …) names to find, and a find with no (of …) asks " &
                 "every object on stdin and a space of every (Q A) record. " &
                 "Asked again as each value arrives, it writes each answer " &
                 "once."),
  Builtin(name: "walk", arity: 0, ask: walk,
          summary: "every subvalue of each value, depth first, the value " &
                   "itself first",
          about: "Asks about each value on stdin in turn.")]

proc list() =
  ## the searches here, a line each
  var rows: seq[(string, string)]
  for b in builtins:
    rows.add ((b.name & " " & b.query).strip, b.summary)
  for (name, path) in tools("bl-search-"):
    rows.add (name, firstHelpLine(path))
  sayRows rows

proc searchTool(b: Builtin): Tool =
  Tool(name: "search " & b.name, args: b.query, summary: b.summary,
       about: b.about,
       opts: @[Opt(long: "take", short: 'n', arg: "N",
                   help: "take N answers, then stop")],
       run: (t: Tool, a: Args) => (block:
         if a.positional.len != b.arity:
           t.misuse "takes " & $b.arity & " query value(s), got " &
             $a.positional.len
         var query: seq[Value]
         for arg in a.positional:
           try: query.add valueArg(arg)
           except ValueError as e: t.misuse e.msg
         let take = t.intOpt(a, "take", -1)
         if b.run != nil:
           try: b.run(query, take) except ValueError as e: t.misuse e.msg
         else:
           lift(b.ask(query), take = take)))

proc dispatch(t: Tool, argv: seq[string]) =
  ## `bl search`: options before NAME are its own, everything after is
  ## the search's
  if argv.len == 0:
    list()
    return
  let name = argv[0]
  if name in ["-h", "--help"]:
    say t.usage
    return
  if name.startsWith("-"):
    t.misuse "a search's options go after its name: " & name
  for b in builtins:
    if b.name == name:
      b.searchTool.start(argv[1 .. ^1])
      return
  let exe = lookTool("bl-search-" & name)
  if exe.len == 0:
    t.misuse "no search " & name &
      " (no builtin, and no bl-search-" & name & " beside bl or on PATH)"
  execTool @[exe] & argv[1 .. ^1]

const About = """
NAME names a search and the QUERY values are what it is asked, each read
by recognition: a file if one exists, otherwise the argument; CE if it
decodes, otherwise the textual syntax. The values on stdin are what this
run of the search can reach, and its answers are written as CE as they
are pulled: downstream reading the pipe is pulling them, `-n N` takes N
and stops, a closed pipe stops it quietly. On a stdin that never closes
it keeps answering as values arrive.

A NAME this bl doesn't have runs bl-search-NAME, from beside bl or
from PATH, with the rest of the arguments. With no NAME, lists the
searches here, builtin and found, with a line each. `bl search NAME --help` says more about one.
"""

proc entry(): Tool =
  result = Tool(
    name: "search",
    args: "[NAME [QUERY…] [-n N]]",
    summary: "ask a search about the values on stdin; its answers go to stdout",
    about: About)
  let usage = result # what `dispatch` says on a misuse
  result.raw = (argv: seq[string]) => dispatch(usage, argv)

let tool* = entry()
