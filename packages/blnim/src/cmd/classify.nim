import std/[sequtils, strutils]
import ../core
import ../lib/grammar
import ./[gsource, store, util]

const help = """
bl classify [options] <grammar>

Says which of a grammar's rules admit each value from stdin.
Recognition is additive, so every rule that speaks is named and none of
them is the value's type.

  (readings {file fsentry} {} <the value>)

The first set is what admitted it, the second is what the budget
refused to answer for. With --split, each reading is its own utterance
instead: (reading file <the value>).

Options:
  --rule:NAME    ask only this rule; repeatable
  --split        one (reading name value) per accepting rule
  --deep         classify subvalues too
  --budget:N     judgment budget per rule per value (default 1000000)
  --store:PATH   where names resolve
"""

proc run*(args: seq[string]) =
  var
    spec = ""
    only: seq[string]
    split = false
    deep = false
    budget = DefaultBudget
    root = defaultStoreRoot()
  for kind, key, val in cmdOpts(
    args, shortNoVal = {'h'}, longNoVal = @["split", "deep", "help"]
  ):
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "h", "help":
        echo help
        return
      of "rule":
        only.add val
      of "split":
        split = true
      of "deep":
        deep = true
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
        quit "unknown classify option: " & key & "\n\n" & help
    else:
      if spec != "":
        quit "classify takes one grammar\n\n" & help
      spec = key

  var g = grammarFrom(spec, root)
  var names = g.ruleNames
  if only.len > 0:
    for n in only:
      if n notin names:
        quit "this grammar names no rule '" & n & "'"
    names = only

  let pristine = g
  let ceiling = 8 * g.patCount + 4096

  proc consider(v: Value) =
    if g.patCount > ceiling:
      g = pristine
    let r = g.readings(v, names, budget)
    if split:
      for n in r.accepted:
        emit record(sym"reading", sym(n), v)
    else:
      emit record(
        sym"readings", set(r.accepted.mapIt(sym(it))), set(r.refused.mapIt(sym(it))), v
      )

  eachValue(
    stdin,
    proc(v: Value) =
      consider v
      if deep:
        for c in v.allChildren:
          consider c
    ,
  )
