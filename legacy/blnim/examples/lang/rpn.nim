## A stack dialect, done by one doer: `!(rpn [WORD …])`.
##
## The block is the dialect's own. Nothing outside looks into it, and the
## dialect looks no further than a mark:
##
## - a marked word is handed back to the cx doing the dialect, and each
##   of its answers is pushed, so the dialect has several answers
##   wherever what it hands back does;
## - `dup`, `drop`, `swap` and `over` work the stack;
## - any other word the dialect has an arity for takes that many values
##   off the stack and is done as a call, `(WORD A B)`, by whatever doers
##   are in reach, each answer pushed: the dialect has no arithmetic of
##   its own. A word whose call answers nothing ends that branch, so
##   `lt` is a guard here too;
## - any other symbol refuses;
## - anything else unmarked, a frame included, is pushed as it is.
##
## Each branch answers what is on top of its stack at the end.
##
##   !(rpn [2 3 add 4 mul])                        20
##   !(rpn [!(in [1 2 3]) dup mul])                1 4 9
##   !(add !(rpn [6 7 mul]) 1)                     43

import std/tables
import bl/lang

refuseWith BasslineError

type Rpn* = ref object of Doer
  ## the stack dialect, and the arity of each word it does as a call
  arity: Table[Value, int]

let RpnQ = sym"rpn"

proc rpn*(arity: openArray[(string, int)] = {"add": 2, "sub": 2, "mul": 2,
          "div": 2, "mod": 2, "lt": 2, "le": 2, "gt": 2, "ge": 2, "eq": 2,
          "ne": 2, "compare": 2}): Rpn =
  ## the dialect, doing each word named in `arity` as a call of that many
  ## values off the stack
  result = Rpn()
  for (word, n) in arity: result.arity[sym(word)] = n

proc step(d: Rpn, cx: Cx, st, word: Value): Stream[Value] =
  ## every stack one word leaves, from one stack
  let items = st.items.data
  let n = items.len
  proc pushed(a: Value): Value = initList(items & a)
  if word.mark:
    return cx.eval(word).map(pushed)
  if not word.isKind(bSym):
    return just pushed(word)
  proc needs(k: int) =
    guard n >= k, "rpn: " & word.text & " wants " & $k & " on the stack, has " & $n
  case word.text
  of "dup":
    needs 1
    return just pushed(items[^1])
  of "drop":
    needs 1
    return just initList(items[0 ..< n - 1])
  of "swap":
    needs 2
    return just initList(items[0 ..< n - 2] & @[items[^1], items[^2]])
  of "over":
    needs 2
    return just pushed(items[^2])
  else: discard
  guard word in d.arity, "rpn has no word " & word.text
  let k = d.arity[word]
  needs k
  let rest = items[0 ..< n - k]
  let call = word.initRec(items[n-k ..< n], true)
  cx.eval(call).maps(initList(rest & it))

proc after(d: Rpn, cx: Cx, states: Stream[Value], word: Value): Stream[Value] =
  ## the stacks after one more word, each branch taking turns
  states.fair(st => d.step(cx, st, word), cx.refused)

method fits*(d: Rpn, v: Value): bool =
  v.isKind(bRec) and v.items.len == 2 and v.items[1].isKind(bList, unmarked)

method answers*(d: Rpn, v: Value, cx: Cx): Stream[Value] =
  var states = just initList()
  for word in v.items[1].items.data:
    states = d.after(cx, states, word)
  states.maps(block:
    guard it.items.len > 0, "rpn: nothing on the stack at the end"
    it.items[^1])

method describe*(d: Rpn): Value =
  var
    words = initList([sym"dup", sym"drop", sym"swap", sym"over"])
    calls = initDict()
  for word, n in d.arity:
    calls[word] = num(n)
  RpnQ.initRec([words, calls])

proc install*(cx: Cx, d: Rpn) =
  ## !(rpn [WORD …]) done by d
  cx.install(RpnQ, d)

when isMainModule:
  import std/strutils
  let cx = base()
  cx.install(rpn())
  let script = rv"""[
    !(rpn [2 3 add 4 mul])
    !(rpn [!(in [1 2 3]) dup mul])
    !(add !(rpn [6 7 mul]) 1)
    !(rpn [!(in [1 5 2 7]) dup 4 lt])
    !(describe rpn)
  ]"""
  for each in script.items:
    var got: seq[string]
    for a in cx.eval(each): got.add "  " & $a
    echo $each, "  =>  \n", got.join("  ")