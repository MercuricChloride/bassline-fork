## bl eval: do each value on stdin, write what doing it answers

import std/[strutils, sugar]
import harness
import bl/lang

proc rulesIn(path: string): seq[Value] =
  ## the rules a file holds: text if it ends in .bl, else CE; each value a
  ## rule, or a list or set of them
  var held: seq[Value]
  if path.endsWith(".bl"):
    held.add readValue(readFile(path))
  else:
    let s = openSource(path)
    s.eachValue((v: Value) => held.add v)
    s.close()
  for v in held:
    if v.isKind({bList, bSet}, unmarked):
      for r in v.parts: result.add r
    else: result.add v

proc run(t: Tool, a: Args) =
  if a.positional.len > 0:
    t.misuse "takes no arguments: the values to do come on stdin"
  let take = t.intOpt(a, "take", -1)
  let quiet = a.has("quiet")
  proc unheard(v: Value) =
    if not quiet: chatter "bl eval: nothing here does " & $v
  proc refused(e: ref BasslineError) =
    if not quiet: chatter "bl eval: passed over: " & e.msg
  let around = base(unheard, refused)
  around.numeric
  let cx = around.within  # the rules given, found before the vocabulary
  for path in a.every("with"):
    try: cx.install(rules(rulesIn(path)))
    except ValueError as e: fail "bl eval: " & path & ": " & e.msg
  try: lift(cx.search, take = take)
  except BasslineError as e: fail "bl eval: " & e.msg

let tool* = Tool(
  name: "eval",
  summary: "do each value on stdin, writing what it answers",
  about: """
Reads CE from stdin and does each value as it arrives, writing every
answer as CE. An unmarked value answers itself; a marked one is done by
the base vocabulary and the numbers over vectors (`!(add 1 2)`,
`!(all [!(in [1 2 3])])`, `!(fn [x] [!(mul x! x!)])`), and by the rules
in each FILE given with --with, `(rule (shape EXAMPLE {HOLE …}) BODY)`,
found before them. A value nothing here can do answers nothing, and is
said on stderr; a refusal ends the run.""",
  opts: @[Opt(long: "with", arg: "FILE",
              help: "rules to do values with, as text (.bl) or CE; again for more"),
          Opt(long: "take", short: 'n', arg: "N",
              help: "take N answers in all, then stop"),
          Opt(long: "quiet", short: 'q',
              help: "say nothing on stderr of what nothing does")],
  run: run)
