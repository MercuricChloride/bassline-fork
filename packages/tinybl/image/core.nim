## The forms an image boots with. Each is a native object in the root,
## found like any other name, and each scheme is an object that answers
## `(>>resolve FORM)` with the place FORM names.

import kernel
export kernel

refuseWith BasslineError

useValue Val

{.push raises: [BasslineError].}

proc nameIn(v: Val, msg: Val): Val =
  guard v.kind == bSym, "a name is a symbol: " & $v & " in " & $msg
  v

# ================
# Evaluation
# ================

proc quoteN(msg, self, sender: Val): Val {.native: "quote".} =
  ## (quote V)
  ## V as written, unevaluated.
  matchValue msg:
  of "($_ $v)": v
  else: refuse "(quote V) takes one value: " & $msg

proc doN(msg, self, sender: Val): Val {.native: "do".} =
  ## (do FORM …)
  ## Each form in turn, answering the last, or nil when there is none.
  matchValue msg:
  of "($_ &body) {any-mark}": body.evalBody(sender)
  else: null

proc ifN(msg, self, sender: Val): Val {.native: "if".} =
  ## (if TEST THEN ELSE?)
  ## THEN when TEST isn't nil, otherwise ELSE or nil. nil is the only false.
  matchValue msg:
  of "($_ $test $then)":
    if test.eval(sender).kind != bNil: then.eval(sender) else: null
  of "($_ $test $then $otherwise)":
    if test.eval(sender).kind != bNil: then.eval(sender) else: otherwise.eval(sender)
  else: refuse "(if TEST THEN ELSE?): " & $msg

proc evalN(msg, self, sender: Val): Val {.native: "eval".} =
  ## (eval EXPR SCOPE?)
  ## What EXPR evaluates to, evaluated again in SCOPE, or here.
  matchValue msg:
  of "($_ $x)": x.eval(sender).eval(sender)
  of "($_ $x $scope)": x.eval(sender).eval(scope.eval(sender))
  else: refuse "(eval EXPR SCOPE?): " & $msg

proc sendN(msg, self, sender: Val): Val {.native: ">>send".} =
  ## (>>send MSG REF)
  ## MSG, unevaluated, sent to what REF names, which is then self.
  matchValue msg:
  of "($_ $m $r)":
    let obj = r.deref(sender)
    send(m, obj, obj, sender)
  else: refuse "(>>send MSG REF): " & $msg

# ================
# Names and places
# ================

proc defN(msg, self, sender: Val): Val {.native: "def".} =
  ## (def NAME EXPR)
  ## NAME, in this scope, now holds what EXPR evaluates to.
  matchValue msg:
  of "($_ $name $x)":
    result = x.eval(sender)
    sender.slotPut(name.nameIn(msg), result)
  else: refuse "(def NAME EXPR): " & $msg

proc setN(msg, self, sender: Val): Val {.native: "set".} =
  ## (set REF EXPR)
  ## The place REF names now holds what EXPR evaluates to.
  matchValue msg:
  of "($_ $r $x)":
    let place = r.resolve(sender)
    result = x.eval(sender)
    place.put result
  else: refuse "(set REF EXPR): " & $msg

proc getN(msg, self, sender: Val): Val {.native: "get".} =
  ## (get REF)
  ## What the place REF names holds, so `(get [c1 count])` reads a path.
  matchValue msg:
  of "($_ $r)": r.deref(sender)
  else: refuse "(get REF): " & $msg

proc refN(msg, self, sender: Val): Val {.native: "ref".} =
  ## (ref REF)
  ## The place REF names, as an object receiving (>>get) and (>>put V).
  matchValue msg:
  of "($_ $r)": r.resolve(sender)
  else: refuse "(ref REF): " & $msg

proc atN(msg, self, sender: Val): Val {.native: "at".} =
  ## (at FRAME KEY)
  ## FRAME's member at KEY: a list's or record's by position, a dict's by key.
  ## As a reference, a put builds the frame anew and puts it back.
  let a = msg.args(sender)
  guard a.len == 2, "(at FRAME KEY): " & $msg
  a[0].member(a[1])

proc atR(form, scope: Val): Val {.resolver: "at".} =
  guard form.len == 3, "(at REF KEY): " & $form
  newObject(newAtPlace(form.getChild(1).resolve(scope), form.getChild(2).eval(scope)))

proc slotN(msg, self, sender: Val): Val {.native: "slot".} =
  ## (slot OBJ NAME)
  ## What OBJ answers NAME with, its own slot or one it delegates to.
  let a = msg.args(sender)
  guard a.len == 2, "(slot OBJ NAME): " & $msg
  send(a[1].nameIn(msg), a[0], a[0], sender)

proc slotR(form, scope: Val): Val {.resolver: "slot".} =
  guard form.len == 3, "(slot REF NAME): " & $form
  let
    obj = form.getChild(1).eval(scope)
    name = form.getChild(2).eval(scope).nameIn(form)
  newObject(newSlotPlace(obj.slotFor(name), name))

# ================
# Objects
# ================

proc makeN(msg, self, sender: Val): Val {.native: "make".} =
  ## (make PROTO {NAME: EXPR …}?)
  ## A new object delegating to PROTO, nil for none, with a slot for each name.
  var table: SortedTable[Val, Val]
  matchValue msg:
  of "($_ $proto)":
    let p = proto.eval(sender)
    if p.kind != bNil: table[sParent] = p
  of "($_ $proto $slots)":
    let p = proto.eval(sender)
    if p.kind != bNil: table[sParent] = p
    # `{}` reads as an empty set, so it says no slots too
    guard slots.kind == bDict or (slots.kind == bSet and slots.len == 0),
      "(make PROTO {NAME: EXPR …}): " & $msg
    if slots.kind == bDict:
      for (name, x) in slots.dict.pairs:
        table[name.nameIn(msg)] = x.eval(sender)
  else: refuse "(make PROTO {NAME: EXPR …}?): " & $msg
  newObject(newSlots(table))

proc lambdaIn(made, sender: Val): Val =
  ## a function made in a call keeps that call as its `>>parent`
  result = made
  if sender.isActivation:
    var table: SortedTable[Val, Val]
    table[sParent] = sender
    result.layers.add newSlots(table)

proc fnN(msg, self, sender: Val): Val {.native: "fn".} =
  ## (fn [PARAM …] FORM …)
  ## A function. Called, it evaluates each argument where the call is, binds
  ## it to a param, and answers its last form, evaluated in a scope below
  ## self, or below the call it was made in.
  matchValue msg:
  of "($_ $params &body)":
    guard params.kind == bList, "(fn [PARAM …] FORM …): " & $msg
    for p in params.children:
      discard p.nameIn(msg)
    newObject(newFn(params, body)).lambdaIn(sender)
  else: refuse "(fn [PARAM …] FORM …): " & $msg

proc opN(msg, self, sender: Val): Val {.native: "op".} =
  ## (op FORM …)
  ## Like fn, but nothing is evaluated for it: the message is >>message and
  ## the scope it came from is >>sender.
  matchValue msg:
  of "($_ &body)": newObject(newOp(body)).lambdaIn(sender)
  else: refuse "(op FORM …): " & $msg

proc idN(msg, self, sender: Val): Val {.native: "id".} =
  ## (id ID)
  ## The object in the image with that id.
  let a = msg.args(sender)
  guard a.len == 1, "(id ID): " & $msg
  result = a[0].byId
  guard not result.isNil, "no object " & $msg

proc idOfN(msg, self, sender: Val): Val {.native: "id-of".} =
  ## (id-of OBJ)
  ## OBJ's id, or nil when it has no place in the image yet.
  let a = msg.args(sender)
  guard a.len == 1, "(id-of OBJ): " & $msg
  result = a[0].idOf
  if result.isNil: result = null

proc nativeN(msg, self, sender: Val): Val {.native: "native".} =
  ## (native NAME)
  ## The host's native NAME, an error when the host has none.
  matchValue msg:
  of "($_ $name)": nativeObject(name.nameIn(msg).text)
  else: refuse "(native NAME): " & $msg

# ================
# Layers
# ================

proc layerN(msg, self, sender: Val): Val {.native: "layer".} =
  ## (layer OBJ HEAD)
  ## How OBJ's layer HEAD is written, or nil. As a reference, putting a form
  ## reads it onto OBJ in place of that layer, and putting nil takes it off.
  matchValue msg:
  of "($_ $obj $head)":
    let found = obj.eval(sender).layerNamed(head.nameIn(msg))
    result = if found.isNil: null else: found.mold
  else: refuse "(layer OBJ HEAD): " & $msg

proc layerR(form, scope: Val): Val {.resolver: "layer".} =
  guard form.len == 3, "(layer REF HEAD): " & $form
  newObject(newLayerPlace(form.getChild(1).eval(scope), form.getChild(2).nameIn(form)))

proc layersN(msg, self, sender: Val): Val {.native: "layers".} =
  ## (layers OBJ)
  ## The set of how OBJ's layers are written. As a reference, putting a set
  ## makes those OBJ's layers.
  let a = msg.args(sender)
  guard a.len == 1, "(layers OBJ): " & $msg
  a[0].layerForms

proc layersR(form, scope: Val): Val {.resolver: "layers".} =
  guard form.len == 2, "(layers REF): " & $form
  newObject(newLayersPlace(form.getChild(1).eval(scope)))

{.pop.}

# ================
# Booting
# ================

let sRoot* = headSym">>root-scope"

proc nativeEntry(name: string): Val =
  ## the root's object for the native or scheme called name, with its doc
  result = newObject()
  let doit = natives.getOrDefault(name)
  if not doit.isNil:
    result.layers.add newNative(name, doit)
  let scheme = resolvers.getOrDefault(name)
  if not scheme.isNil:
    result.layers.add newResolver(name, scheme)
  let doc = nativeDocs.getOrDefault(name)
  if doc.len > 0:
    result.layers.add newDoc(Val.buildAtom(doc, bText, false))

proc boot*(): Val {.raises: [BasslineError].} =
  ## a new image whose root holds an object for each native and scheme the
  ## host has, and `>>root-scope`, the root itself. Answers the root
  freshImage()
  let root = newObject()
  root.identify
  image.root = root
  var names: seq[string]
  for name in natives.keys:
    names.add name
  for name in resolvers.keys:
    if name notin natives:
      names.add name
  for name in names:
    root.slotPut(headSym(name), nativeEntry(name))
  root.slotPut(sRoot, root)
  root

proc workspace*(parent: Val): Val {.raises: [BasslineError].} =
  ## an object in the image below parent, to evaluate in
  var table: SortedTable[Val, Val]
  table[sParent] = parent
  result = newObject(newSlots(table))
  result.identify

proc run*(scope: Val, text: string): Val {.raises: [BasslineError].} =
  ## each value text holds evaluated in scope, answering the last
  result = null
  var forms: seq[Val]
  try:
    forms = Val.parseMany(text)
  except Exception as e:
    refuse "not values: " & e.msg
  for each in forms:
    result = each.eval(scope)
