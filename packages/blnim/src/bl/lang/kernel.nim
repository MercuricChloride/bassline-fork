## The kernel: doing marked values.
##
## An unmarked value is something, not something to do. Done, it answers
## itself, whole: nothing inside it is done, so an unmarked frame defers
## the marked values it holds until something chooses to do them. A
## marked value is something to do, and what doing it answers is a
## stream, found by asking the doers within reach.
##
## A call is a marked record, `!(HEAD ARG …)`, or by name `!(HEAD !{NAME:
## ARG …})`, whose marked dict is made with its marked values done, as any
## marked argument is (an unmarked one is handed over as said). Its direct
## marked arguments are done before the call, whatever the head, each answer crossed fairly with the others', and everything else
## is handed over as said; so anyone can tell from the value alone what
## runs before the call, knowing nothing of the head. A marked head is
## done first and its answer heads the call, so a function held in a
## variable is called as `!(f! 3)`. An unmarked head is only ever the
## name doers are found by.
##
## The call so bound goes to the doers found for it, nearest first. The
## first that fits it and answers gives every answer it has; one that
## answers nothing, or refuses, passes it on to the next. If nothing
## answers and something refused, the refusal is raised; if nothing so
## much as fits, nothing is answered and `unheard` hears it. A refusal is
## about one call: where answers fan out, a branch that refuses has
## nothing and the others go on (`refused` hears it), and only a fan-out
## with no answer at all raises it. A doer that does something rather
## than finding something says so as it acts (`acted`) and answers that
## it did; from then on the call is its own, and nothing it answers or
## refuses is passed on to another doer to do again. An act is done when
## the answer it belongs to is pulled: a consumer that takes one answer
## of an action that fans out has done one branch's acts, and one that
## means them all pulls every answer.
##
## Any other marked value is handed whole to the doers found for it: a
## marked symbol, `x!`, is first a variable, the nearest binding of `x`;
## a marked set is an object, its doers found by its `!(kind K)` orders;
## a marked list or dict by its kind of frame.
##
## A doer that needs the stream of a computation, to see whether it
## answers, to take every answer, or to choose when it runs, takes a
## block: an unmarked list of forms, done when and where the doer
## chooses (`run`), by the rule a call's arguments are: each form once
## for each answer of the one before. A doer that needs values takes
## direct arguments.
##
## A doer nearer stands in for those further out, so a cx can hold its
## own way of doing a head inside one that holds another; every doer's
## answers are a different question, `readings`. A nearer doer whose
## first answer never comes holds up those further out.
##
## A cx is where a value is done: variables, doers, and the cx around
## it. Variables are bindings made by binding a function's parameters or
## a `let`, one per name and branch; a function's body sees its own and
## those it captured, and no further out (a sealed level). Doers are
## found through every level, so what a portable function calls is found
## where it is applied.

import std/[options, tables]
import ../[core, queries]
export core, queries

refuseWith BasslineError

const MaxEvalDepth* {.intdefine.} = 1000
  ## how many function and rule bodies may be entered one inside another.
  ## A debug build's own call limit comes first unless raised past it
  ## (-d:nimCallDepthLimit=32000 does)

type
  Doer* = ref object of RootObj
    ## something that can do some marked values: those it fits, it does,
    ## answering a stream

  Level = ref object
    vars: BDict                     ## names to what they're bound to
    doers: Table[Value, seq[Doer]]  ## doers by the key they are found by
    found: seq[Search[Value, Doer]] ## more places doers are found
    sealed: bool                    ## variables are looked for no further

  Cx* = ref object
    ## where a value is done
    level: Level
    outer*: Cx
    acts: ref int ## how many acts have been done here and within
    depth*: int
    unheard*: (Value) -> void ## hears what nothing in reach could do
    refused*: (ref BasslineError) -> void
      ## hears a refusal passed over, where another branch or doer goes on

method fits*(d: Doer, v: Value): bool {.base.} =
  ## whether d can do v, bound as it is: a probe, building nothing
  true

method answers*(d: Doer, v: Value, cx: Cx): Stream[Value] {.base.} =
  ## what doing v answers, done in cx
  refuse "a doer with no answers"

method describe*(d: Doer): Value {.base.} =
  ## what d says it does, as a value; nil if it says nothing
  null()

# ================ where values are done ================

proc newCx*(unheard: (Value) -> void = nil,
            refused: (ref BasslineError) -> void = nil): Cx =
  ## an empty cx, with nothing in reach
  result = Cx(level: Level(vars: newBDict()), unheard: unheard,
              refused: refused)
  result.acts = new int

proc within*(cx: Cx, vars = newBDict(), sealed = false, deeper = false): Cx =
  ## a cx inside cx, binding `vars`; sealed, a variable is looked for no
  ## further out. A body entered is deeper, refused past MaxEvalDepth
  let depth = cx.depth + ord(deeper)
  guard depth <= MaxEvalDepth,
    "more than " & $MaxEvalDepth & " bodies entered one inside another"
  Cx(level: Level(vars: vars, sealed: sealed), outer: cx, acts: cx.acts,
     depth: depth, unheard: cx.unheard, refused: cx.refused)

proc install*(cx: Cx, key: Value, doers: varargs[Doer]) =
  ## doers found here by key, by this cx and every cx within it
  for d in doers:
    cx.level.doers.mgetOrPut(key, @[]).add d

proc install*(cx: Cx, found: Search[Value, Doer]) =
  ## a search asked, for each marked value done here, what may do it
  cx.level.found.add found

proc acted*(cx: Cx) =
  ## said by a doer that does something rather than finding something,
  ## as it does it: from then on the call it is doing is its own, so a
  ## refusal or nothing from it is never passed on to another doer
  inc cx.acts[]

proc lookup*(cx: Cx, name: Value): Option[Value] =
  ## the nearest binding of name, looked for out to a sealed level
  var c = cx
  while c != nil:
    if name in c.level.vars: return some c.level.vars[name]
    if c.level.sealed: return
    c = c.outer

func unmarked(v: Value): Value =
  result = v
  result.mark = false

proc headKey(h: Value): Value =
  ## a call's head, or, for a head that is itself a record such as a
  ## function's value, its head, all the way in
  matchValue h:
  of "($head &_)": headKey(head)
  else: h

proc keys*(v: Value): seq[Value] =
  ## what doers for v are found by: a call's head; an object's kinds, as
  ## (kind K); a marked symbol itself; any other value's (frame KIND)
  case v.kind
  of bRec:
    if v.items.len > 0: return @[headKey(v.items[0])]
  of bSym: return @[v]
  of bSet:
    for m in v.els:
      matchValue m:
      of "!(kind $k)": result.add bl"(kind $k)"
      else: discard
    if result.len > 0: return
  else: discard
  let kind = sym($v.kind)
  @[bl"(frame $kind)"]

proc asking(s: Search[Value, Doer], v: Value): Stream[Doer] =
  lazy(() => s[v])

proc listed[T](xs: seq[T]): Stream[T] =
  ## each of xs in turn. The kernel's streams are plain procs, not
  ## closure iterators, which ORC's cycle collector has been seen to free
  ## while they are still held
  var i = 0
  () -> Option[T] => (block:
    if i < xs.len:
      result = some(xs[i])
      inc i)

proc concat[T](parts: seq[Stream[T]]): Stream[T] =
  ## each stream in turn, the next only once the one before has nothing
  var i = 0
  () -> Option[T] => (block:
    while i < parts.len:
      result = parts[i]()
      if result.isSome: return
      inc i)

proc doersFor*(cx: Cx, v: Value): Stream[Doer] =
  ## the doers in reach that may do v, nearest first
  let ks = v.keys
  var parts: seq[Stream[Doer]]
  var c = cx
  while c != nil:
    if c.level.doers.len > 0:
      var here: seq[Doer]
      for k in ks:
        if k in c.level.doers: here.add c.level.doers[k]
      if here.len > 0: parts.add listed(here)
    for s in c.level.found: parts.add s.asking(v)
    c = c.outer
  concat parts

# ================ doing ================

proc eval*(cx: Cx, v: Value): Stream[Value]

type Passed = ref object
  ## refusals passed over on the way to an answer. They are heard once
  ## something answers; if nothing does, the first is raised instead, for
  ## whoever catches it to hear
  hear: (ref BasslineError) -> void
  answered: bool
  first: ref BasslineError
  waiting: seq[ref BasslineError]

proc over(p: Passed, e: ref BasslineError) =
  if p.first == nil: p.first = e
  if p.answered:
    if p.hear != nil: p.hear(e)
  else: p.waiting.add e

proc answer(p: Passed) =
  if p.answered: return
  p.answered = true
  if p.hear != nil:
    for e in p.waiting: p.hear(e)
  p.waiting = @[]

proc ended(p: Passed) =
  if not p.answered and p.first != nil: raise p.first

proc fair*[T](s: Stream[T], f: (T) -> Stream[Value],
              refused: (ref BasslineError) -> void = nil): Stream[Value] =
  ## f's answers for each of s's, taking turns, so no one of them, nor an
  ## endless s, holds up the others. A branch that refuses has nothing,
  ## and `refused` hears it; if no branch answers and one refused, the
  ## refusal is raised
  let passed = Passed(hear: refused)
  proc branch(v: T): Stream[Value] =
    var b: Stream[Value] = nil
    () -> Option[Value] => (block:
      try:
        if b == nil: b = f(v)
        result = b()
      except BasslineError as e:
        passed.over(e)
        b = empty(Value))
  let turns = altFrom(() => (block:
    let x = s()
    if x.isSome: some(branch(x.get)) else: none(Stream[Value])))
  () -> Option[Value] => (block:
    result = turns()
    if result.isSome: passed.answer
    else: passed.ended)

proc crossing(cx: Cx, items: seq[Value], at: seq[int], i: int,
              build: (seq[Value]) -> Value): Stream[Value] =
  ## every way the items at `at[i..]` can be done, each in its place
  if i == at.len: return just build(items)
  let place = at[i]
  cx.eval(items[place]).fair(a => (block:
    var next = items
    next[place] = a
    cx.crossing(next, at, i + 1, build)), cx.refused)

proc doneItems*(cx: Cx, items: seq[Value], start: int,
                build: (seq[Value]) -> Value): Stream[Value] =
  ## the items with each marked one from `start` on done, crossed fairly
  var at: seq[int]
  for i in start ..< items.len:
    if items[i].mark: at.add i
  if at.len == 0: return just build(items)
  cx.crossing(items, at, 0, build)

proc bound*(cx: Cx, call: Value): Stream[Value] =
  ## every way the call's direct marked arguments can be done
  let mark = call.mark
  cx.doneItems(call.items.data, 1, items => initRec(items, mark))

proc dispatch*(cx: Cx, v: Value): Stream[Value] =
  ## v handed to the doers in reach, nearest first: the first that fits
  ## and answers gives its answers
  let doers = cx.doersFor(v)
  let passed = Passed(hear: cx.refused)
  var
    current: Stream[Value] = nil
    fitted = false
    over = false ## it has ended, and stays ended however often pulled
  () -> Option[Value] => (block:
    if over: return
    if current != nil:
      try:
        result = current()
      except BasslineError as e:
        # it has answered: its refusal ends its answers, as a branch's
        passed.over(e)
      if result.isNone: over = true
      return
    over = true # until a doer answers; a raise leaves it ended
    while true:
      let d = doers()
      if d.isNone:
        passed.ended
        if not fitted and cx.unheard != nil: cx.unheard(v)
        return none(Value)
      if not d.get.fits(v): continue
      fitted = true
      let acted = cx.acts[]
      try:
        let s = d.get.answers(v, cx)
        let first = s()
        if first.isSome:
          current = s
          over = false
          passed.answer
          return first
      except BasslineError as e:
        # one that has acted owns the call: it isn't passed on
        if cx.acts[] != acted: raise e
        passed.over(e)
      if cx.acts[] != acted: return none(Value))

proc withHead(call, head: Value): Value =
  var items = call.items.data
  items[0] = head
  initRec(items, call.mark)

proc calls(cx: Cx, v: Value): Stream[Value] =
  ## every way v can be bound: for a call, its marked head done, then its
  ## direct marked arguments; any other value as it is
  if not v.isKind(bRec, marked): return just v
  guard v.items.len > 0, "a call has a head"
  if v.items[0].mark:
    cx.eval(v.items[0]).fair(h => cx.bound(v.withHead(h)), cx.refused)
  else:
    cx.bound(v)

proc readings*(cx: Cx, v: Value): Stream[Value] =
  ## every answer of every doer in reach that fits v, v bound as for
  ## doing it, the doers taking turns so none holds up another. A doer
  ## that refuses has nothing, and only if none answers is it raised. An
  ## act has no other readings: once a doer acts, no doer further out is
  ## asked. An unmarked v answers itself, as doing it does
  if not v.mark: return just v
  cx.calls(v).fair(b => (block:
    let doers = cx.doersFor(b)
    let before = cx.acts[]
    let fitting = () -> Option[Doer] => (block:
      if cx.acts[] != before: return
      while true:
        result = doers()
        if result.isNone or result.get.fits(b): return)
    fitting.fair(d => d.answers(b, cx), cx.refused)), cx.refused)

proc eval*(cx: Cx, v: Value): Stream[Value] =
  ## what doing v answers here
  if not v.mark: return just v
  case v.kind
  of bRec:
    cx.calls(v).fair(b => cx.dispatch(b), cx.refused)
  of bSym:
    let x = cx.lookup(v.unmarked)
    if x.isSome: just x.get
    else: cx.dispatch(v)
  else:
    cx.dispatch(v)

proc run*(cx: Cx, b: Value): Stream[Value] =
  ## a block done as a call's arguments are: each form done once for each
  ## answer of the one before it, and not at all when it has none, and
  ## the last's answers answered. So a block of tests is all of them, and
  ## an act follows what it follows. A value that isn't an unmarked list
  ## is done as one form
  if not b.isKind(bList, unmarked): return cx.eval(b)
  if b.items.len == 0: return empty Value
  let forms = b.items.data
  proc after(i: int): Stream[Value] =
    if i == forms.high: return cx.eval(forms[i])
    cx.eval(forms[i]).fair(_ => after(i + 1), cx.refused)
  lazy(() => after(0))

proc value*(cx: Cx, v: Value): Option[Value] =
  ## v's first answer here, if it has one
  cx.eval(v)()

proc search*(cx: Cx): Search[Value, Value] =
  ## doing values here as a search: asked a value, what doing it answers,
  ## so it composes with spaces and other searches like any one
  newSearch[Value, Value](v => cx.eval(v))
