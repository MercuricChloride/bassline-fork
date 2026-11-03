## do and load: a small evaluator over values. Everything a value can do
## here is a layer on its node: an Env looks names up and defines them, a
## Place gets and puts, a Call is invoked with the whole form and the env,
## and a Locate turns a form into a Place, so `set` takes generalized
## references. Nothing is a Nim closure: a layer carries what it closes
## over as fields.
##
## An env is a dict of names and the forms that define them. Loading reads
## those forms into layers, with no evaluation, and saving writes each
## entry's form back from its layers.

import std/[macros, sequtils, strutils, tables]
import tinybl

refuseWith BasslineError

useValue Val

layers:
  Place
  Cell(held: Val) of Place
  At(frame: Place, key: Val) of Place
  Env(entries: SortedTable[Val, Val])

type
  NativeProc = proc(form, env: Val): Val {.nimcall, raises: [BasslineError].}
  LocateProc = proc(form, env: Val): Place {.nimcall, raises: [BasslineError].}

layers:
  Call
  Native(name: string, doit: NativeProc) of Call
  Closure(form: Val, env: Val) of Call
  Operative(form: Val, env: Val) of Call
  Locate(name: string, doit: LocateProc)

var
  natives: Table[string, NativeProc]
  locators: Table[string, LocateProc]

let
  parentKey = bl">>parent"
  rootKey = bl">>root-scope"

template null: untyped =
  Val.buildNull(false)

proc same(a, b: Val): bool =
  ## whether a and b are one node, not only equal values
  cast[pointer](a) == cast[pointer](b)

proc eval(v, env: Val): Val {.raises: [BasslineError].}

macro native(called: string, def: untyped) =
  ## `{.native: "NAME".}` on `proc p(form, env: Val): Val` makes p the native
  ## that `(native NAME)` reads as
  let p = def.name
  def.addPragma nnkExprColonExpr.newTree(ident"raises",
    nnkBracket.newTree(bindSym"BasslineError"))
  quote do:
    `def`
    natives[`called`] = `p`

macro locator(called: string, def: untyped) =
  ## `{.locator: "NAME".}` on `proc p(form, env: Val): Place` makes p how a
  ## form headed by the native NAME names a place
  let p = def.name
  def.addPragma nnkExprColonExpr.newTree(ident"raises",
    nnkBracket.newTree(bindSym"BasslineError"))
  quote do:
    `def`
    locators[`called`] = `p`

# ================
# Envs
# ================

proc envOf(v: Val): Env =
  result = v.layers[Env]
  guard not result.isNil, "not an env: " & $v

proc lookup(env, name: Val): Val =
  ## name's entry in env or the nearest env above it
  var at = env
  while true:
    let e = at.envOf
    result = e.entries.getOr(name, nil)
    if not result.isNil:
      return
    at = e.entries.getOr(parentKey, nil)
    guard not at.isNil, "unbound: " & $name

proc define(env, name, entry: Val) =
  env.envOf.entries[name] = entry

proc scope(parent: Val): Val =
  ## a new env below parent
  var entries: SortedTable[Val, Val]
  entries[parentKey] = parent
  result = Val.buildFrame(@[], bDict, false)
  result.layers.add newEnv(entries)

proc cell(v: Val): Val =
  ## an entry holding v as a variable
  result = bl"(place $v)"
  result.layers.add newCell(v)

# ================
# Places
# ================

method get(p: Place): Val {.base, raises: [BasslineError].} =
  refuse "a place with nothing to get"

method put(p: Place, v: Val) {.base, raises: [BasslineError].} =
  refuse "a place with nowhere to put"

method get(p: Cell): Val = p.held

method put(p: Cell, v: Val) = p.held = v

proc index(frame, key: Val): int =
  guard key.kind == bNum and key.num.isInt, "not an index: " & $key
  result = key.num.toInt
  guard result in 0 ..< frame.len, "no member " & $key & " in " & $frame

proc member(frame, key: Val): Val =
  case frame.kind
  of bList, bRec:
    result = frame.getChild(frame.index(key))
  of bDict:
    result = frame.dict.getOr(key, nil)
    guard not result.isNil, "no key " & $key & " in " & $frame
  else: refuse "no members in " & $frame

proc replaced(frame, key, v: Val): Val =
  ## frame with the member at key replaced by v
  case frame.kind
  of bList, bRec:
    var items = frame.items
    items[frame.index(key)] = v
    Val.buildFrame(items, frame.kind, frame.mark)
  of bDict:
    guard key in frame.dict, "no key " & $key & " in " & $frame
    var flat: seq[Val]
    for (k, x) in frame.dict.pairs:
      flat.add k
      flat.add(if k == key: v else: x)
    Val.buildFrame(flat, bDict, frame.mark)
  else: refuse "no members in " & $frame

method get(p: At): Val = p.frame.get.member(p.key)

method put(p: At, v: Val) =
  ## a value doesn't change, so the frame is built anew and put where it was
  p.frame.put p.frame.get.replaced(p.key, v)

proc locate(form, env: Val): Place =
  ## the place form names: a symbol's entry, or what the Locate of a
  ## record's head makes of it
  case form.kind
  of bSym:
    result = env.lookup(form).layers[Place]
    guard not result.isNil, "not a place: " & $form
  of bRec:
    let head = form.getChild(0).eval(env)
    let loc = head.layers[Locate]
    guard not loc.isNil, "names no place: " & $form
    result = loc.doit(form, env)
  else: refuse "names no place: " & $form

# ================
# Calls
# ================

method invoke(c: Call, form, env: Val): Val {.base, raises: [BasslineError].} =
  refuse "not callable: " & $form

method invoke(c: Native, form, env: Val): Val = c.doit(form, env)

proc params(lambda: Val): Val =
  result = lambda.getChild(1)
  guard result.kind == bList and result.children.toSeq.allIt(it.kind == bSym),
    "params are a list of names: " & $lambda

proc body(lambda: Val, env: Val): Val =
  result = null
  for i in 2 ..< lambda.len:
    result = lambda.getChild(i).eval(env)

method invoke(c: Closure, form, env: Val): Val =
  ## each argument evaluated where the call is, bound in a scope below the
  ## env the closure was made in
  let params = c.form.params
  guard form.len - 1 == params.len, $c.form & " takes " & $params.len
  let local = scope(c.env)
  for i in 0 ..< params.len:
    local.define(params.getChild(i), cell(form.getChild(i + 1).eval(env)))
  c.form.body(local)

method invoke(c: Operative, form, env: Val): Val =
  ## the form and the caller's env, unevaluated, bound to its two params
  let params = c.form.params
  guard params.len == 2, "op takes [FORM ENV]: " & $c.form
  let local = scope(c.env)
  local.define(params.getChild(0), cell(form))
  local.define(params.getChild(1), cell(env))
  c.form.body(local)

proc onRecord(self: Call, v: Val): bool {.binder.} = v.kind == bRec

proc eval(v, env: Val): Val =
  ## a node carrying a Call answers itself, a symbol what its entry's Place
  ## holds or else the entry, and a record is handed to the Call its head
  ## evaluates to. Anything else answers itself
  if v.hasLayer(Call):
    return v
  case v.kind
  of bSym:
    let entry = env.lookup(v)
    let place = entry.layers[Place]
    if place.isNil: entry else: place.get
  of bRec:
    let head = v.getChild(0).eval(env)
    let call = head.layers[Call]
    guard not call.isNil, "not callable: " & $head
    call.invoke(v, env)
  else: v

# ================
# Load and save
# ================

proc readNative(v: Val): Native {.reader.} =
  matchValue v:
  of "(native $name)":
    if name.kind == bSym:
      let doit = natives.getOrDefault(name.text)
      if not doit.isNil:
        return newNative(name.text, doit)
  else: discard

proc readLocate(v: Val): Locate {.reader.} =
  matchValue v:
  of "(native $name)":
    if name.kind == bSym:
      let doit = locators.getOrDefault(name.text)
      if not doit.isNil:
        return newLocate(name.text, doit)
  else: discard

proc readCell(v: Val): Cell {.reader.} =
  matchValue v:
  of "(place $held)": newCell(held)
  else: nil

proc load(v: Val, parent: Val = nil): Val

proc declare(form, env: Val, entry: bool) =
  ## reads form's layers, a lambda's over env. An entry must declare
  ## something, and what a place holds may be plain data
  matchValue form:
  of "(native $name)":
    let (call, loc) = (form.attach(Native), form.attach(Locate))
    guard not (call.isNil and loc.isNil), "no native named " & $name
  of "(place $held)":
    discard form.attach(Cell)
    held.declare(env, false)
  of "(fn &_)":
    form + newClosure(form, env)
  of "(op &_)":
    form + newOperative(form, env)
  else:
    if form.kind == bDict and entry:
      discard load(form, env)
    else:
      guard not entry, "declares nothing: " & $form

proc load(v: Val, parent: Val = nil): Val =
  ## the env v spells, a dict of names and the forms that define them, below
  ## parent. An env with no parent is the root, `>>root-scope`
  guard v.kind == bDict, "load reads a dict: " & $v
  var entries: SortedTable[Val, Val]
  for (name, form) in v.dict.pairs:
    entries[name] = form
  if parent.isNil:
    entries[rootKey] = v
  else:
    entries[parentKey] = parent
  v.layers.add newEnv(entries)
  for (name, form) in v.dict.pairs:
    form.declare(v, true)
  v

proc written(v, env: Val): Val =
  ## v as a load value writes it: a lambda as its form, which only reads
  ## back over the env being saved
  let lambda =
    if v.hasLayer(Closure): v.layers[Closure].env
    elif v.hasLayer(Operative): v.layers[Operative].env
    else: nil
  guard lambda.isNil or lambda.same(env),
    "a lambda over a scope that isn't saved with it: " & $v
  v

proc save(env: Val): Val =
  ## the load value that rebuilds env, each entry's form written from its
  ## layers as they are now
  var flat: seq[Val]
  for (name, entry) in env.envOf.entries.pairs:
    if name == parentKey or name == rootKey:
      continue
    flat.add name
    let place = entry.layers[Cell]
    if not place.isNil:
      let held = place.held.written(env)
      flat.add bl"(place $held)"
    elif entry.hasLayer(Env):
      flat.add entry.save
    else:
      flat.add entry.written(env)
  Val.buildFrame(flat, bDict, false)

# ================
# Foundational
# ================

proc doQuote(form, env: Val): Val {.native: "quote".} =
  matchValue form:
  of "($_ $v)": v
  else: refuse "quote takes one value: " & $form

proc doIf(form, env: Val): Val {.native: "if".} =
  ## nil is the only false
  matchValue form:
  of "($_ $test $then)":
    if test.eval(env).kind != bNil: then.eval(env) else: null
  of "($_ $test $then $otherwise)":
    if test.eval(env).kind != bNil: then.eval(env) else: otherwise.eval(env)
  else: refuse "if takes a test and one or two branches: " & $form

proc doDo(form, env: Val): Val {.native: "do".} =
  result = null
  matchValue form:
  of "($_ &body) {any-mark}":
    for each in body:
      result = each.eval(env)
  else: discard

proc doDef(form, env: Val): Val {.native: "def".} =
  matchValue form:
  of "($_ $name $v)":
    guard name.kind == bSym, "def names a symbol: " & $form
    result = v.eval(env)
    env.define(name, cell(result))
  else: refuse "def takes a name and a value: " & $form

proc doSet(form, env: Val): Val {.native: "set".} =
  matchValue form:
  of "($_ $place $v)":
    let p = place.locate(env)
    result = v.eval(env)
    p.put result
  else: refuse "set takes a place and a value: " & $form

proc doFn(form, env: Val): Val {.native: "fn".} =
  discard form.params
  result = form.fresh
  result + newClosure(result, env)

proc doOp(form, env: Val): Val {.native: "op".} =
  discard form.params
  result = form.fresh
  result + newOperative(result, env)

proc doEval(form, env: Val): Val {.native: "eval".} =
  matchValue form:
  of "($_ $x $e)": x.eval(env).eval(e.eval(env))
  else: refuse "eval takes a value and an env: " & $form

proc doScope(form, env: Val): Val {.native: "scope".} =
  matchValue form:
  of "($_ $e)": scope(e.eval(env))
  else: refuse "scope takes an env: " & $form

# ================
# The host's
# ================

proc args(form, env: Val): seq[Val] =
  for i in 1 ..< form.len:
    result.add form.getChild(i).eval(env)

proc doPrint(form, env: Val): Val {.native: "print".} =
  echo form.args(env).mapIt(if it.kind == bText: it.text else: $it).join(" ")
  null

proc doAdd(form, env: Val): Val {.native: "add".} =
  var total: BNum = 0
  for each in form.args(env):
    guard each.kind == bNum, "add takes numbers: " & $form
    total = total + each.num
  Val.buildAtom($total, bNum, false)

proc doEq(form, env: Val): Val {.native: "eq".} =
  ## the first argument when the second equals it, and nil otherwise
  let a = form.args(env)
  guard a.len == 2, "eq takes two values: " & $form
  if a[0] == a[1]: a[0] else: null

proc doRecord(form, env: Val): Val {.native: "record".} =
  let a = form.args(env)
  guard a.len > 0, "a record has a head: " & $form
  Val.buildFrame(a, bRec, false)

proc doAt(form, env: Val): Val {.native: "at".} =
  let a = form.args(env)
  guard a.len == 2, "at takes a frame and a key: " & $form
  a[0].member(a[1])

proc atPlace(form, env: Val): Place {.locator: "at".} =
  guard form.len == 3, "at takes a frame and a key: " & $form
  newAt(form.getChild(1).locate(env), form.getChild(2).eval(env))

# ================
# Running
# ================

let
  root = load bl"""{
    quote: (native quote) if: (native if) do: (native do) def: (native def)
    set: (native set) fn: (native fn) op: (native op) eval: (native eval)
    scope: (native scope)
    print: (native print) add: (native add) eq: (native eq)
    record: (native record) at: (native at)
  }"""
  mezzanineText = bl"""{
    when: (op [form env] (if (eval (at form 1) env) (eval (at form 2) env)))
    unless: (op [form env] (if (eval (at form 1) env) nil (eval (at form 2) env)))
    or: (op [form env]
      ((fn [a] (if a a (eval (at form 2) env))) (eval (at form 1) env)))
    inc: (op [form env]
      (eval (record (quote set) (at form 1) (record (quote add) (at form 1) 1)) env))
  }"""
  mezzanine = load(mezzanineText, root)
  user = scope(mezzanine)

proc run(env, script: Val) =
  discard script.eval(env)

echo "mezzanine saves as it loaded: ", mezzanine.save == mezzanineText

user.run bl"""
  !(do
    (def x 1)
    (inc x)
    (print "x is" x)
    (def xs [1 2 3])
    (set (at xs 0) 10)
    (inc (at xs 2))
    (print xs)
    (def twice (fn [n] (add n n)))
    (print (twice 21))
    (when (eq x 2) (print "x is 2"))
    (print (or nil "or falls through"))
    (print (eval (quote (add 1 2)) >>root-scope)))
"""

let saved = user.save
echo "user saves as: ", saved

let again = load(saved, mezzanine)
again.run bl"""!(do (inc x) (print "loaded again, x is" x (twice x)))"""

user.run bl"""
  !(do
    (def counter (fn [] ((fn [count] (fn [] (inc count))) 0)))
    (def c (counter))
    (c)
    (c)
    (print "counted" (c)))
"""