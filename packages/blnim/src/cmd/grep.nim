import std/strutils
import ../core
import ../lib/[grammar, print]
import ./[gsource, store, util]

const help = """
bl grep [options] <grammar>

Passes on the values from stdin that a grammar admits. The grammar is
inline text, a file of text or canonical bytes, or a name the store
holds.

  bl listen | bl grep shape.bl | bl cat
  bl cat log.blb | bl grep '{start: (point !(num) !(num))}'

Options:
  --rule:NAME    judge by this rule instead of `start`
  --deep         emit matching subvalues too, not just whole values
  --invert       pass on what the rule does not admit
  --count        emit how many matched instead of what matched
  --explain      write why each rejected value missed, to stderr
  --budget:N     judgment budget per value (default 1000000)
  --store:PATH   where names resolve

Exits 0 when something matched, 1 when nothing did, and 2 when the
budget refused a value: refusal is not rejection.
"""

proc run*(args: seq[string]) =
  var
    spec = ""
    wanted = ""
    deep = false
    invert = false
    count = false
    explain = false
    budget = DefaultBudget
    root = defaultStoreRoot()
  for kind, key, val in cmdOpts(
    args,
    shortNoVal = {'h'},
    longNoVal = @["deep", "invert", "count", "explain", "help"],
  ):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "rule":
        wanted = val
      of "deep":
        deep = true
      of "invert":
        invert = true
      of "count":
        count = true
      of "explain":
        explain = true
      of "budget":
        try:
          budget = parseInt(val)
        except ValueError:
          quit "--budget wants a number of steps, got: " & val
        if budget <= 0:
          quit "--budget must be positive"
      of "store":
        if val == "":
          quit "--store needs a path"
        root = val
      else:
        quit "unknown grep option: " & key & "\n\n" & help
    else:
      if spec != "":
        quit "grep takes one grammar\n\n" & help
      spec = key

  var g = grammarFrom(spec, root)
  let rule = g.startingRule(wanted)

  # Every judgment interns residuals, so a long-lived filter learns
  # automaton until it has learned all of it. That is bounded, but the
  # bound can be large, so keep the snapshot and fall back to it.
  let pristine = g
  let ceiling = 8 * g.patCount + 4096
  var
    passed = 0
    refused = 0

  proc consider(v: Value) =
    if g.patCount > ceiling:
      g = pristine
    var admits = false
    case g.judge(rule, v, budget)
    of vAccepted:
      admits = true
    of vRejected:
      if explain:
        # diagnosis walks further than judgment did, so it can run out
        # where judgment did not: say so rather than die
        try:
          let m = g.explain(rule, v, budget)
          if m.isSome:
            stderr.writeLine $m.get.toValue
        except BudgetError:
          stderr.writeLine "-- rejected, but explaining it ran past the budget"
    of vRefused:
      inc refused
      stderr.writeLine "-- refused after " & $budget & " steps"
      return
    if admits != invert:
      inc passed
      if not count:
        emit v

  eachValue(
    stdin,
    proc(v: Value) =
      consider v
      if deep:
        for c in v.allChildren:
          consider c
    ,
  )

  if count:
    emit num($passed)
  if refused > 0:
    quit 2
  quit(if passed > 0: 0 else: 1)
