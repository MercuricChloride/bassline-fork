## Shapes: values with holes, and the search for what fills them.
##
## A shape is an example value and a set of holes, parts of the example
## that stand for whatever is in their place. Written down it is
##
##   (shape EXAMPLE {HOLE …})  or  (shape EXAMPLE {HOLE …} WILD)
##
## where WILD, in the example, fits anything and binds nothing.
##
## Filling a shape is a little unification search: asked about a value,
## it answers every binding of the holes, {HOLE: VALUE …}, under which the
## value fits the example, one per pull and nothing worked out ahead. A
## value fits where it has the example's kind and mark, and
##
## - a list or record has at least the example's members, the leading
##   ones each fitting the example's in its place;
## - a dict has, for each of the example's entries, an entry whose key and
##   value fit;
## - a set has, for each of the example's members, a member that fits;
## - an atom is the example's.
##
## A key or member with a hole or the wild anywhere in it is tried against
## each of the value's keys or members in turn; one with neither is looked
## up as it is. Two parts of the example may be filled from the same key or
## member: a set example says which members a value has, not how many. A
## hole fits a value of its own mark, and a hole met again fits only what
## it is bound to already, so the bindings found are compatible: a hole
## bound two ways is no filling, never an error. A filling binds every
## hole, and each is answered once. A search can start from bindings
## already had, and answers only those compatible with them.
##
## Each part of the example is a search from bindings to every extension
## of them under which the value's part fits it, and a frame's is its
## parts' one after another: first what the bindings already decide,
## then what has one place to fit, then the part whose candidates are
## fewest by its known leading members, so checks come before anything
## branches. A list or record member is looked for only among those of its
## kind and mark that begin with the members already known, found by
## bisecting. `inject` goes the other way, filling holes from bindings.
##
## A dialect built on shapes can read some parts of an example its own way,
## as forms (`fitting`): a form is never looked up as written, and fits as
## the dialect says, given the fit for any other part.

import std/[options, sequtils]
import ../core
import ./[queries, stream]
export queries, stream

refuseWith BasslineError

blet("{shape}", false)

type
  Shape* = object
    example*: Value        ## what a value that fits looks like
    holes*: BSet           ## parts of the example standing for what is there
    wild*: Option[Value]   ## a part that fits anything and binds nothing

  Fit* = (Value) -> Stream[Value]
    ## every extension of the bindings `b` under which a value fits a part

  Forms* = object
    ## parts of an example read their own way: `isForm` says which, and
    ## `fitForm` fits one, given the fit for any other part. Nil for none
    isForm*: (Value) -> bool
    fitForm*: (Value, Value, (Value, Value) -> Fit) -> Fit

  Fitter = object
    ## a shape's holes, its wild and the forms read their own way: what
    ## fitting it needs
    holes: BSet
    wild: Option[Value]
    forms: Forms

proc initShape*(example: Value, holes: openArray[Value],
                wild = none(Value)): Shape =
  Shape(example: example, holes: toBTreeSet(holes), wild: wild)

proc fromValue*(T: typedesc[Shape], v: Value): Shape =
  ## reads (shape EXAMPLE {HOLE …}) or (shape EXAMPLE {HOLE …} WILD).
  ## Refuses anything else
  matchValue v:
  of "(shape $example $holes)":
    if holes.isKind(bSet, unmarked): return Shape(example: example, holes: holes.els)
  of "(shape $example $holes $wild)":
    if holes.isKind(bSet, unmarked):
      return Shape(example: example, holes: holes.els, wild: some wild)
  else: discard
  refuse "not (shape EXAMPLE {HOLE …}) or (shape EXAMPLE {HOLE …} WILD): " & $v

proc toValue*(s: Shape): Value =
  var fields = @[shape, s.example, initSet(s.holes)]
  if s.wild.isSome: fields.add s.wild.get
  initRec fields

# ================ fitting ================

proc keep(b: Value): Stream[Value] = just b
proc fail(_: Value): Stream[Value] = empty Value

proc then(a, b: Fit): Fit =
  ## `a`, then `b` from each of the bindings `a` answers
  (x: Value) => a(x).flatMap(b)

proc bound(hole, v: Value): Fit =
  ## `hole` bound to `v`: the bindings as they are if it is bound so
  ## already, none if it is bound otherwise
  (b: Value) => (block:
    if hole in b.dict:
      if b.dict[hole] == v: just(b) else: empty(Value)
    else:
      var more = b.copy
      more[hole] = v
      just(more))

proc isWild(s: Fitter, part: Value): bool =
  s.wild == some(part)

proc isForm(s: Fitter, part: Value): bool =
  s.forms.isForm != nil and part notin s.holes and s.forms.isForm(part)

proc isLiteral(s: Fitter, part: Value): bool =
  ## whether `part` has no hole, no wild and no form anywhere in it
  part notin s.holes and not s.isWild(part) and not s.isForm(part) and
    part.parts.every(p => s.isLiteral(p))

proc holesIn(s: Fitter, parts: varargs[Value]): seq[Value] =
  ## the holes anywhere in `parts`
  initStream(@parts).flatMaps(walk(it)).filters(it in s.holes).unique.toSeq

type Choice = object
  ## one part of a frame to fit, the holes it might bind, and, for a part
  ## tried against each candidate in turn, how many leading members its
  ## candidates are narrowed by under some bindings (nil for a part with
  ## one place to fit)
  holes: seq[Value]
  fit: Fit
  lead: (Value) -> int

proc unbound(c: Choice, b: Value): int =
  ## how many of the choice's holes the bindings `b` leave unbound
  for h in c.holes:
    if h notin b.dict: inc result

proc rank(c: Choice, b: Value): (int, int, int) =
  ## which choice to take first, least first: one with nothing left to
  ## bind, which only checks; one with one place to fit, which binds
  ## without branching; then the narrowest by its known leading members,
  ## binding the most holes at once
  let open = c.unbound(b)
  if open == 0: (0, 0, 0)
  elif c.lead == nil: (1, 0, 0)
  else: (2, -c.lead(b), -open)

proc choices(cs: seq[Choice]): Fit =
  ## the choices one after another, the best ranked first each time, so
  ## what the bindings already decide is checked before anything branches
  ## further. A choice with nothing left to bind can only answer the
  ## bindings as they are, so it is asked for one answer
  (b: Value) => (block:
    if cs.len == 0: return just(b)
    var best = 0
    for i in 1 ..< cs.len:
      if cs[i].rank(b) < cs[best].rank(b): best = i
    let rest = choices(cs[0 ..< best] & cs[best + 1 .. ^1])
    if cs[best].unbound(b) == 0:
      return if cs[best].fit(b).next.isSome: rest(b) else: empty(Value)
    cs[best].fit(b).flatMap(rest))

proc fit(s: Fitter, part, v: Value): Fit
proc shaped(s: Fitter, part, v: Value): Fit

proc entryChoice(s: Fitter, key, item, v: Value): Choice =
  ## one entry of an example dict against the dict `v`: a literal key
  ## looked up, any other tried against each entry in turn
  if not s.isLiteral(key):
    return Choice(holes: s.holesIn(key, item),
      lead: (b: Value) => 0,
      fit: (b: Value) => v.entries.flatMaps(s.fit(key, it[0]).then(s.fit(item, it[1]))(b)))
  if key notin v.dict: return Choice(fit: fail)
  Choice(holes: s.holesIn(item), fit: s.fit(item, v.dict[key]))

proc settledLead(s: Fitter, m, b: Value): seq[Value] =
  ## the leading members of a list or record `m` that fit only what equals
  ## them under the bindings `b`: atoms as written, and holes bound
  ## already, as far as they run unbroken
  if not m.isKind({bList, bRec}) or s.isForm(m) or m in s.holes: return
  for x in m.items.data:
    if x in s.holes:
      if x notin b.dict: break
      result.add b.dict[x]
    elif s.isWild(x) or x.isKind({bList, bRec, bDict, bSet}): break
    else: result.add x

proc candidates(s: Fitter, m, v, b: Value): Stream[Value] =
  ## the members of the set `v` that might fit `m` under the bindings `b`:
  ## the one a bound hole stands for, the lists or records of its kind and
  ## mark that begin with its settled lead, or else every member
  if m in s.holes and m in b.dict:
    let w = b.dict[m]
    return if w in v.els: just(w) else: empty(Value)
  if m.isKind({bList, bRec}) and not s.isForm(m) and m notin s.holes:
    return v.els.ledBy(m.kind, s.settledLead(m, b), m.mark)
  v.members

proc memberChoice(s: Fitter, m, v: Value): Choice =
  ## one member of an example set against the set `v`: a literal member
  ## looked up, any other tried against each member that might fit it
  if s.isLiteral(m): return Choice(fit: if m in v.els: keep else: fail)
  Choice(holes: s.holesIn(m),
    lead: (b: Value) => s.settledLead(m, b).len,
    fit: (b: Value) => s.candidates(m, v, b).flatMaps(s.fit(m, it)(b)))

proc fit(s: Fitter, part, v: Value): Fit =
  ## every extension of bindings under which `v` fits `part`
  if s.isForm(part):
    return s.forms.fitForm(part, v, (p, w: Value) => s.fit(p, w))
  if s.isWild(part): return keep
  if part in s.holes:
    if part.mark == v.mark: return bound(part, v)
    # bound otherwise (from bindings given), it still fits what it is bound to
    let otherwise = s.shaped(part, v)
    return (b: Value) => (block:
      if part notin b.dict: otherwise(b)
      elif b.dict[part] == v: just(b)
      else: empty(Value))
  s.shaped(part, v)

proc shaped(s: Fitter, part, v: Value): Fit =
  ## every extension of bindings under which `v` fits `part` as written
  if not part.sameFamily(v): return fail
  case part.kind
  of bList, bRec:
    if v.items.len < part.items.len: return fail
    var cs: seq[Choice]
    for i in 0 ..< part.items.len:
      cs.add Choice(holes: s.holesIn(part.items[i]),
                    fit: s.fit(part.items[i], v.items[i]))
    choices cs
  of bDict: part.entries.maps(s.entryChoice(it[0], it[1], v)).toSeq.choices
  of bSet: part.members.maps(s.memberChoice(it, v)).toSeq.choices
  else: (if part == v: keep else: fail)

proc fitter(s: Shape, forms = Forms()): Fitter =
  Fitter(holes: s.holes, wild: s.wild, forms: forms)

proc fitting*(s: Shape, forms: Forms): (Value, Value) -> Fit =
  ## the fit for any part of `s`'s example against a value, reading `forms`
  ## their own way: the search from bindings to their extensions that a
  ## dialect built on shapes composes its own searches from
  let fr = s.fitter(forms)
  (part, v: Value) => fr.fit(part, v)

# ================ searching and filling ================

proc fillings*(s: Shape, v: Value, given = initDict()): Stream[Value] =
  ## every binding of the holes, {HOLE: VALUE …}, under which `v` fits the
  ## example, extending the bindings `given`: each once, one per pull,
  ## nothing worked out ahead. Refuses `given` if it isn't a dict
  guard given.isKind(bDict, unmarked), "bindings are a dict: " & $given
  let holes = s.holes
  s.fitter.fit(s.example, v)(given)
    .filter(b => holes.between(always, always).every(h => h in b.dict))
    .unique

proc inject*(s: Shape, bindings: Value): Value =
  ## the example with each hole that `bindings` binds filled in, and any
  ## other left as it is. Refuses `bindings` if it isn't a dict
  guard bindings.isKind(bDict, unmarked), "bindings are a dict: " & $bindings
  proc filled(part: Value): Value =
    if part in s.holes and part in bindings.dict: bindings.dict[part]
    elif part.isKind({bList, bRec, bDict, bSet}): part.map(filled)
    else: part
  filled s.example
