import std/strutils
import ../core
import ../lib/print
import ./[gsource, store, util]

const help = """
bl gen [options] <grammar>

Writes values the grammar admits. A productive rule is a generator: it
describes at least one value, and this walks it to build them.

  bl gen shape.bl -n:100 | bl grep shape.bl --count    # says 100

Each run samples differently and says which run it was, so any of them
can be had again with --seed. --size:0 asks for the smallest value the
rule describes, which is one value however many you ask for.

Options:
  --rule:NAME    generate for this rule instead of `start`
  -n:COUNT       how many values (default 1)
  --seed:N       repeat a particular run; without one, a run is picked
                 and its seed written to stderr
  --size:K       how much structure to spend past the smallest (default 6)
  --no-verify    skip judging each value against the rule it came from
  --store:PATH   where names resolve
"""

proc run*(args: seq[string]) =
  var
    spec = ""
    wanted = ""
    count = 1
    seed = 0
    seeded = false
    size = 6
    verify = true
    root = defaultStoreRoot()
  for kind, key, val in cmdOpts(
    args, shortNoVal = {'h'}, longNoVal = @["no-verify", "help"]
  ):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "rule":
        wanted = val
      of "n", "count":
        try:
          count = parseInt(val)
        except ValueError:
          quit "-n wants a number, got: " & val
        if count < 0:
          quit "-n must not be negative"
      of "seed":
        try:
          seed = parseInt(val)
        except ValueError:
          quit "--seed wants a number, got: " & val
        seeded = true
      of "size":
        try:
          size = parseInt(val)
        except ValueError:
          quit "--size wants a number, got: " & val
        if size < 0:
          quit "--size must not be negative"
      of "no-verify":
        verify = false
      of "store":
        if val == "":
          quit "--store needs a path"
        root = val
      else:
        quit "unknown gen option: " & key & "\n\n" & help
    else:
      if spec != "":
        quit "gen takes one grammar\n\n" & help
      spec = key

  var g = grammarFrom(spec, root)
  let rule = g.startingRule(wanted)
  var rng = seededRand(seed, seeded)
  let pr = g.productivity
  let p = g.rulePattern(rule)
  if pr.isEmpty(p):
    quit "'" & rule & "' describes no value, so there is nothing to write"
  for _ in 0 ..< count:
    let v = g.generate(pr, p, rng, size)
    if v.isNone:
      quit "'" & rule & "' describes values this cannot build; see bl grammar lint"
    if verify:
      case g.judge(rule, v.get)
      of vRejected:
        quit "built a value '" & rule & "' does not admit: " & $v.get
      of vRefused:
        stderr.writeLine "-- built a value the budget could not check"
      of vAccepted:
        discard
    emit v.get
