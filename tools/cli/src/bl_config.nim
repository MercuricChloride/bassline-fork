## bl config: this person's own answers, kept in ~/.bl/config.bl, where
## the tools look for what isn't said on their command line or in their
## environment

import std/strutils
import harness

const placeQuestions = [
  ("at", "where the jam's clients look, unless --at or JAM_AT says"),
  ("as", "the name you go by on a jam, unless --as or JAM_NAME says"),
  ("send", "where bl send speaks given no place"),
  ("serve", "where bl serve listens given no place"),
  ("listen", "where bl jam serve listens given no place")]

proc answerArg(s: string): Value =
  ## an answer given on the command line: a symbol when it is a name, a
  ## letter, then letters, digits, '.', '_' and '-', else text, a path or
  ## a place among them
  if isName(s): sym(s) else: text(s)

proc check(t: Tool, q: Value, answer: string) =
  ## a place where a tool takes one: refused when it is neither a place
  ## nor a name
  if not q.isKind(bSym) or q.text notin ["at", "send", "serve", "listen"]:
    return
  if isName(answer):
    return
  try: discard parsePlace(answer, allowZero = q.text in ["serve", "listen"])
  except ValueError as e: t.misuse e.msg

proc run(t: Tool, a: Args) =
  if a.positional.len == 0:
    if a.has("forget") or a.has("add"):
      t.misuse "--forget and --add take a question"
    for v in configValues(): emit v
    return
  let q =
    try: readValue(a.positional[0])
    except ValueError as e: t.misuse "the question " & a.positional[0] & " doesn't read: " & e.msg
  let answers = a.positional[1 .. ^1]
  if a.has("forget"):
    if answers.len > 1: t.misuse "--forget takes a question and one answer at most"
    let one = if answers.len == 1: some answerArg(answers[0]) else: none(Value)
    if not forget(q, one): fail "the config has no such answer"
    return
  if answers.len == 0:
    if a.has("add"): t.misuse "--add takes a question and its answers"
    for answer in configured(q): emit initRec(@[q, answer])
    return
  var values: seq[Value]
  for answer in answers:
    t.check(q, answer)
    values.add answerArg(answer)
  configure(q, values, adding = a.has("add"))

proc defaults(t: Tool, args: seq[string]) =
  ## `defaults TOOL… [OPTION…]`: the options TOOL is given by default
  ## become OPTION…, or, with none, are written
  var words: seq[string]
  var i = 0
  while i < args.len and not args[i].startsWith("-"):
    words.add args[i]
    inc i
  if words.len == 0:
    if i < args.len:
      t.misuse "defaults names the tool first: bl config defaults jam serve --clave"
    for v in configValues():
      let qa = answerOf(v)
      if qa.isSome and qa.get[0].isKind(bRec, unmarked) and qa.get[0].head == sym"defaults":
        emit v
    return
  let q = defaultsQ(words.join(" "))
  if i == args.len:
    for answer in configured(q): emit initRec(@[q, answer])
    return
  var answers: seq[Value]
  while i < args.len:
    let arg = args[i]
    if not arg.startsWith("--") or arg.len < 3:
      t.misuse "after the tool come its options, --NAME or --NAME VALUE, not " & arg
    var name = arg[2 .. ^1]
    var value = none(string)
    let sep = name.find({'=', ':'})
    if sep >= 0:
      value = some name[sep + 1 .. ^1]
      name = name[0 ..< sep]
    elif i + 1 < args.len and not args[i + 1].startsWith("-"):
      inc i
      value = some args[i]
    answers.add(if value.isSome: initRec(@[sym(name), answerArg(value.get)]) else: sym(name))
    inc i
  configure(q, answers)

proc questions(): string =
  for (q, about) in placeQuestions:
    result.add "  " & q.alignLeft(8) & about & "\n"

proc runConfig(argv: seq[string])

proc configTool(): Tool = Tool(
  name: "config",
  args: "[Q [A…]] | defaults [TOOL… [OPTION…]]",
  summary: "your own answers, where the tools look for what isn't said",
  about: """
The config, ~/.bl/config.bl, is a run of (Q A) records in the textual
syntax: answers you have given, each question answered as often as it
has answers. A tool looks there for what its command line and
environment don't say:

""" & questions() & """
  (place NAME)  the places a name names (bl name sets these)
  (defaults TOOL…)  the options a tool is given by default

`bl config defaults TOOL… OPTION…` sets a tool's defaults, in place of
those it had: `bl config defaults jam serve --clave` serves every jam
taking signed values only, and `bl config defaults jam --key
~/.bl/keys/goose.blb` signs what you say in bl jam with that key. Each
is kept as ((defaults jam serve) clave), a flag, or ((defaults jam)
(key PATH)), an option and its value. `bl config defaults TOOL…` writes
them, `bl config defaults` all of them, and `bl config --forget
'(defaults jam serve)'` takes them away. What a tool is given on its
command line comes after, so it has the last word, and --no-defaults,
given to any tool, leaves the config's defaults out for that run.

`bl config` writes every answer, `bl config Q` the answers to Q, and
`bl config Q A…` makes A… Q's answers, in place of those it had, or
beside them with --add. --forget Q takes Q's answers away, or one of
them with --forget Q A. Q is a value in the textual syntax, so
'(place NAME)' is quoted for the shell. An answer is a symbol when it is
a name, else text: `bl config at jordan-machine`, `bl config at
192.168.40.237:8456`. The file is yours to edit too, and is rewritten
whole when the config changes, so comments in it don't last.""",
  opts: @[Opt(long: "add", help: "add the answers beside those Q has"),
          Opt(long: "forget", help: "take Q's answers away, or one of them")],
  run: run,
  raw: runConfig)

proc runConfig(argv: seq[string]) =
  let t = configTool()
  if argv.len > 0 and argv[0] == "defaults": t.defaults(argv[1 .. ^1])
  else: t.run(t, t.parse(argv))

let tool* = configTool()
