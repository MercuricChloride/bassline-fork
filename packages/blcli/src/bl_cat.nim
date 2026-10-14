## bl cat: CE to the textual syntax, one value per line

import harness

proc run(t: Tool, a: Args) =
  let width = t.intOpt(a, "width", 0, lo = 1)
  proc show(v: Value) =
    say (if width > 0: pretty(v, width) else: $v) & "\n"
  if a.positional.len == 0:
    stdinSource().eachValue show
  for path in a.positional:
    let s = openSource(path)
    s.eachValue show
    s.close()

let tool* = Tool(
  name: "cat",
  args: "[FILE…]",
  summary: "CE values to the textual syntax, one value per line",
  about: """
Reads CE from each FILE in turn (a .blb), or from stdin with no FILE or
for `-`, and prints each value as soon as it arrives. `bl read` reads
the output back to the same bytes.""",
  opts: @[Opt(long: "width", arg: "N",
              help: "lay each value out within N columns, over several lines")],
  run: run)
