## The image kernel. An object is a node carrying an Identity and other
## layers. `send` hands a message to each of an object's layers in turn and,
## when none understands it, to the object's `>>parent`, keeping `self`, so
## looking a name up and inheriting from a prototype are both delegation.
## The root ends every chain, so its names are found from anywhere.
## A reference resolves to a place, an object that receives `(>>get)` and
## `(>>put V)`. Everything else, from `if` to `make`, is an object in the
## root.
##
## What happens to the image is said as events, values handed to each of
## the image's listeners: `(created ID FORMS)`, `(defined ID NAME NEW)`,
## `(changed ID NAME OLD NEW)`, `(removed ID NAME OLD)`, `(layered ID FORM)`,
## `(unlayered ID FORM)`, and `(sent MSG TO)` while tracing. An object
## written into a value reads `(object ID)`, so an event or a mold that
## holds objects names them by id.

import std/[algorithm, macros, sysrand, tables]
import tinybl
export tinybl, tables

refuseWith BasslineError

useValue Val

type
  NativeProc* = proc(msg, self, sender: Val): Val {.nimcall, raises: [BasslineError].}
    ## a native receiving msg, sent by the scope sender to self
  ResolveProc* = proc(form, scope: Val): Val {.nimcall, raises: [BasslineError].}
    ## the place a reference form names, for a scheme
  Listener* = proc(event: Val) {.nimcall, raises: [].}

layers:
  Identity(id: Val)
  Slots(table: SortedTable[Val, Val])
  Doc(text: Val)
  Behavior
  Native(name: string, doit: NativeProc) of Behavior
  Fn(params: Val, body: seq[Val]) of Behavior
  Op(body: seq[Val]) of Behavior
  Resolver(name: string, doit: ResolveProc)
  Place
  Cell(held: Val) of Place
  ConstPlace(held: Val) of Place
  SlotPlace(obj: Val, name: Val) of Place
  AtPlace(target: Val, key: Val) of Place
  LayerPlace(obj: Val, head: Val) of Place
  LayersPlace(obj: Val) of Place

type Image* = ref object
  root*: Val
  index*: Table[string, Val]
    ## each object in the image by its id's bytes
  listeners*: seq[Listener]
  tracing*: bool

{.push raises: [BasslineError].}

var
  image* = Image()
  natives*: Table[string, NativeProc]
  nativeDocs*: Table[string, string]
  resolvers*: Table[string, ResolveProc]
  nativeObjects: Table[string, Val]

let
  sParent* = headSym">>parent"
  sSelf* = headSym">>self"
  sSender* = headSym">>sender"
  sMessage* = headSym">>message"
  sGet* = headSym">>get"
  sPut* = headSym">>put"
  sResolve* = headSym">>resolve"
  sHeld* = headSym">>held"

template null*: Val =
  Val.buildNull(false)

proc freshImage*() =
  ## an empty image in place of the current one, with nothing cached from it
  image = Image()
  nativeObjects.clear()

proc emit*(event: Val) =
  for each in image.listeners:
    each(event)

proc newId*(): Val =
  ## sixteen random bytes
  var bytes = newString(16)
  try:
    for i, b in urandom(16):
      bytes[i] = char(b)
  except OSError as e:
    refuse "no randomness for an id: " & e.msg
  Val.buildAtom(bytes, bBytes, false)

proc same*(a, b: Val): bool =
  ## whether a and b are one node, not only equal values
  cast[pointer](a) == cast[pointer](b)

proc fromCE*(bytes: string): Val =
  ## the one value bytes hold
  var
    r: TypeReader[Val]
    pos = 0
  guard r.readCE(bytes, pos), "not a whole value"
  guard pos == bytes.len, "more than one value"
  r.value

proc setOf*(members: seq[Val]): Val =
  ## a set of members in any order, each once
  var sorted = members.sorted(cmp)
  var unique: seq[Val]
  for each in sorted:
    if unique.len == 0 or unique[^1] != each:
      unique.add each
  Val.buildFrame(unique, bSet, false)

# ================
# Objects
# ================

proc isObject*(v: Val): bool = v.hasLayer(Identity)

proc idOf*(obj: Val): Val =
  ## obj's id, nil until it has a place in the image
  let ident = obj.layers[Identity]
  if not ident.isNil and ident.id.kind != bNil:
    result = ident.id

proc newObject*(ls: varargs[Layer]): Val =
  ## an object with no id yet, carrying ls
  result = bl"(object)"
  result.layers.add newIdentity(null)
  for each in ls:
    result.layers.add each

proc layerForms*(obj: Val): Val =
  ## the set of what obj's layers are written as, its Identity aside
  var forms: seq[Val]
  for each in obj.layers:
    if each of Identity:
      continue
    let form = each.mold
    if not form.isNil:
      forms.add form
  setOf(forms)

proc objectForm*(obj: Val): Val =
  ## obj written whole, `(object ID {FORM …})`
  let
    id = obj.idOf
    forms = obj.layerForms
  bl"(object $id $forms)"

proc enter*(v: Val)

proc identify*(obj: Val) =
  ## gives obj an id and so a place in the image, and every object its
  ## layers hold one too
  let ident = obj.layers[Identity]
  if ident.id.kind != bNil:
    return
  let id = newId()
  ident.id = id
  image.index[id.bytes] = obj
  obj.value = bl"(object $id)".value
  for each in obj.layers:
    if each of Identity:
      continue
    let form = each.mold
    if not form.isNil:
      form.enter
  let forms = obj.layerForms
  emit bl"(created $id $forms)"

proc enter*(v: Val) =
  ## gives every object v holds that has no id one, so all of it can be
  ## written
  for each in v.walk:
    if each.isObject and each.idOf.isNil:
      each.identify

proc byId*(id: Val): Val =
  ## the object id names in the image, nil when there is none
  if id.kind == bBytes:
    result = image.index.getOrDefault(id.bytes)

let sObject* = headSym"object"

proc placeholder*(id: Val): Val =
  ## the object id names, made bare when the image doesn't hold it yet,
  ## for reading what names it before what it is
  guard id.kind == bBytes, "an id is bytes: " & $id
  result = id.byId
  if result.isNil:
    result = newObject()
    result.layers[Identity].id = id
    image.index[id.bytes] = result
    result.value = bl"(object $id)".value

proc withObjects*(v: Val): Val =
  ## v with each `(object ID)` in it the object ID names, so a written
  ## image, event or form reads back holding the objects it names
  if v.kind == bRec and v.len == 2 and v.getChild(0) == sObject and
      v.getChild(1).kind == bBytes:
    return v.getChild(1).placeholder
  case v.kind
  of bList, bRec, bDict, bSet:
    var
      members: seq[Val]
      changed = false
    for each in v.children:
      let read = each.withObjects
      changed = changed or not read.same(each)
      members.add read
    result = if changed: Val.buildFrame(members, v.kind, v.mark) else: v
  else:
    result = v

proc fillObject*(obj, forms: Val) =
  ## reads each written layer form in the set forms onto obj, whose
  ## `(object ID)`s name objects, refusing a form no layer reads
  guard forms.kind == bSet, "an object's layers are a set: " & $forms
  for form in forms.withObjects.children:
    let made = readLayer(form)
    guard not made.isNil, "no layer reads " & $form
    obj.layers.add made

# ================
# Slots
# ================

proc ownSlot*(obj, name: Val): Val =
  ## what obj's own slot name holds, nil when it has none
  let slots = obj.layers[Slots]
  if not slots.isNil:
    result = slots.table.getOr(name, nil)

proc parentOf*(obj: Val): Val = obj.ownSlot(sParent)

proc upFrom(at: Val, sawRoot: var bool): Val =
  ## what at delegates to: its `>>parent`, and the root once every chain
  ## ends, so the root's names are found from anywhere
  if not image.root.isNil and at.same(image.root):
    sawRoot = true
  result = at.parentOf
  if result.isNil and not sawRoot and not image.root.isNil:
    sawRoot = true
    result = image.root

proc holderOf*(obj, name: Val): Val =
  ## the object, obj or one it delegates to, whose own slot name is
  var
    at = obj
    sawRoot = false
  while not at.isNil:
    if not at.ownSlot(name).isNil:
      return at
    at = at.upFrom(sawRoot)

proc slotFor*(obj, name: Val): Val =
  ## where a put into obj's slot name goes: the object obj delegates to by
  ## its own `>>parent` links that has it, or else obj itself. The root
  ## ending every chain is for finding names, never for putting into them
  var at = obj
  while not at.isNil:
    if not at.ownSlot(name).isNil:
      return at
    at = at.parentOf
  obj

proc slotPut*(obj, name, v: Val) =
  ## obj's own slot name now holds v. An object in the image says so
  var slots = obj.layers[Slots]
  if slots.isNil:
    slots = newSlots(default(SortedTable[Val, Val]))
    obj.layers.add slots
  let old = slots.table.getOr(name, nil)
  slots.table[name] = v
  let id = obj.idOf
  if not id.isNil:
    v.enter
    if old.isNil:
      emit bl"(defined $id $name $v)"
    else:
      emit bl"(changed $id $name $old $v)"

proc slotRemove*(obj, name: Val) =
  let slots = obj.layers[Slots]
  if slots.isNil:
    return
  let old = slots.table.getOr(name, nil)
  if old.isNil:
    return
  slots.table.delete(name)
  let id = obj.idOf
  if not id.isNil:
    emit bl"(removed $id $name $old)"

proc slotNames*(obj: Val): seq[Val] =
  let slots = obj.layers[Slots]
  if not slots.isNil:
    for (name, _) in slots.table.pairs:
      result.add name

# ================
# Layers on objects
# ================

proc headOf*(l: Layer): Val =
  ## the head l is written under, nil when it isn't written
  let form = l.mold
  if not form.isNil and form.kind == bRec:
    result = form.getChild(0)

proc layerNamed*(obj, head: Val): Layer =
  for each in obj.layers:
    if not (each of Identity) and each.headOf == head:
      return each

proc putLayer*(obj, form: Val) =
  ## reads form onto obj in place of the layer written under its head
  let made = readLayer(form)
  guard not made.isNil, "not a layer: " & $form
  guard not (made of Identity), "an id isn't put as a layer"
  let old = obj.layerNamed(form.getChild(0))
  if not old.isNil:
    obj.layers.remove old
  obj.layers.add made
  let id = obj.idOf
  if not id.isNil:
    form.enter
    if not old.isNil:
      let was = old.mold
      emit bl"(unlayered $id $was)"
    emit bl"(layered $id $form)"

proc dropLayer*(obj, head: Val) =
  let old = obj.layerNamed(head)
  if old.isNil:
    return
  obj.layers.remove old
  let id = obj.idOf
  if not id.isNil:
    let was = old.mold
    emit bl"(unlayered $id $was)"

# ================
# Sending
# ================

method receive*(l: Layer, obj, msg, self, sender: Val): Val {.base, raises: [BasslineError].} =
  ## what l answers msg, sent to obj for self by the scope sender, and nil
  ## when l doesn't understand it
  nil

proc call*(msg, callee, self, sender: Val): Val =
  ## msg handed to what callee does, its Behavior
  for each in callee.layers:
    if each of Behavior:
      let got = each.receive(callee, msg, self, sender)
      if not got.isNil:
        return got
  refuse "not callable: " & $callee & " in " & $msg

proc send*(msg, obj, self, sender: Val): Val =
  ## msg to obj's layers, then to whatever it delegates to, self kept
  if image.tracing:
    emit bl"(sent $msg $obj)"
  var
    at = obj
    sawRoot = false
  while not at.isNil:
    for each in at.layers:
      let got = each.receive(at, msg, self, sender)
      if not got.isNil:
        return got
    at = at.upFrom(sawRoot)
  if msg.kind == bSym:
    refuse "unbound: " & $msg
  refuse "not understood: " & $msg & " by " & $obj

proc selfOf*(scope: Val): Val =
  ## who a scope evaluates for: an activation's `>>self`, or the scope
  result = scope.ownSlot(sSelf)
  if result.isNil:
    result = scope

proc isMsg(msg, head: Val, width: int): bool =
  msg.kind == bRec and msg.len == width and msg.getChild(0) == head

proc get*(place: Val): Val =
  send(bl"(>>get)", place, place, place)

proc put*(place, v: Val) =
  discard send(bl"(>>put $v)", place, place, place)

proc nativeObject*(name: string): Val =
  ## the host's native name as an object, one for each name
  result = nativeObjects.getOrDefault(name)
  if result.isNil:
    let doit = natives.getOrDefault(name)
    guard not doit.isNil, "no native named " & name
    result = newObject(newNative(name, doit))
    nativeObjects[name] = result

proc eval*(form, scope: Val): Val

proc resolve*(r, scope: Val): Val =
  ## the place the reference r names, seen from scope
  case r.kind
  of bSym:
    let holder = scope.holderOf(r)
    guard not holder.isNil, "unbound: " & $r
    result = newObject(newSlotPlace(holder, r))
  of bList:
    guard r.len > 0, "an empty path names nothing"
    if r.len == 1:
      return r.getChild(0).resolve(scope)
    var obj = r.getChild(0).eval(scope)
    for i in 1 ..< r.len - 1:
      obj = send(r.getChild(i), obj, obj, scope)
    let name = r.getChild(r.len - 1)
    result = newObject(newSlotPlace(obj.slotFor(name), name))
  of bRec:
    let head = r.getChild(0)
    if head.kind == bSym:
      case head.text
      of "id":
        guard r.len == 2, "(id ID) names one object: " & $r
        let obj = r.getChild(1).byId
        guard not obj.isNil, "no object " & $r
        return newObject(newConstPlace(obj))
      of "native":
        guard r.len == 2 and r.getChild(1).kind == bSym, "(native NAME): " & $r
        return newObject(newConstPlace(nativeObject(r.getChild(1).text)))
      of "quote":
        guard r.len == 2, "(quote V) takes one value: " & $r
        return newObject(newConstPlace(r.getChild(1)))
      else: discard
    let scheme = head.eval(scope)
    result = send(bl"(>>resolve $r)", scheme, scheme, scope)
    guard result.hasLayer(Place), $r & " names no place"
  else:
    refuse "not a reference: " & $r

proc deref*(r, scope: Val): Val = r.resolve(scope).get

proc eval*(form, scope: Val): Val =
  ## A symbol is sent to scope, and so looked up, and so is a record headed
  ## by one. A record headed by a path `([A … NAME] ARG …)` is the message
  ## `(NAME ARG …)` sent to what `[A …]` names, which is then self. A
  ## record headed by a record is handed to what that head evaluates to.
  ## Anything else answers itself
  case form.kind
  of bSym:
    result = send(form, scope, scope.selfOf, scope)
  of bRec:
    let head = form.getChild(0)
    case head.kind
    of bSym:
      result = send(form, scope, scope.selfOf, scope)
    of bList:
      guard head.len > 0, "an empty path names nothing: " & $form
      if head.len == 1:
        var items = form.items
        items[0] = head.getChild(0)
        return Val.buildFrame(items, bRec, form.mark).eval(scope)
      var prefix: seq[Val]
      for i in 0 ..< head.len - 1:
        prefix.add head.getChild(i)
      let obj = Val.buildFrame(prefix, bList, false).deref(scope)
      var items = form.items
      items[0] = head.getChild(head.len - 1)
      result = send(Val.buildFrame(items, bRec, form.mark), obj, obj, scope)
    of bRec:
      result = call(form, head.eval(scope), scope.selfOf, scope)
    else:
      refuse "not callable: " & $head & " in " & $form
  else:
    result = form

proc evalBody*(body: openArray[Val], scope: Val): Val =
  result = null
  for each in body:
    result = each.eval(scope)

proc activation*(callee, msg, self, sender: Val): Val =
  ## where a call is evaluated: its own slots, then callee's `>>parent` when
  ## it was made in a call, and otherwise self
  var table: SortedTable[Val, Val]
  let parent = callee.ownSlot(sParent)
  table[sParent] = if parent.isNil: self else: parent
  table[sSelf] = self
  table[sSender] = sender
  table[sMessage] = msg
  newObject(newSlots(table))

proc isActivation*(scope: Val): bool = not scope.ownSlot(sMessage).isNil

proc isProtocol(msg: Val): bool =
  ## `(>>get)`, `(>>put V)` and `(>>resolve FORM)`, which a call never is
  msg.kind == bRec and msg.getChild(0) in [sGet, sPut, sResolve]

# ================
# Layers receiving
# ================

method receive(l: Slots, obj, msg, self, sender: Val): Val =
  case msg.kind
  of bSym:
    l.table.getOr(msg, nil)
  of bRec:
    let head = msg.getChild(0)
    if head.kind == bSym:
      let held = l.table.getOr(head, nil)
      if not held.isNil:
        return call(msg, held, self, sender)
    nil
  else:
    nil

method receive(l: Native, obj, msg, self, sender: Val): Val =
  if not msg.isProtocol:
    result = l.doit(msg, self, sender)

method receive(l: Fn, obj, msg, self, sender: Val): Val =
  ## each argument evaluated where the call is, bound to a param
  if msg.kind != bRec or msg.isProtocol:
    return nil
  guard msg.len - 1 == l.params.len,
    $msg & ": takes " & $l.params.len & " for " & $l.params
  let act = activation(obj, msg, self, sender)
  let table = act.layers[Slots]
  for i in 0 ..< l.params.len:
    table.table[l.params.getChild(i)] = msg.getChild(i + 1).eval(sender)
  l.body.evalBody(act)

method receive(l: Op, obj, msg, self, sender: Val): Val =
  ## the message and the sender as they are, `>>message` and `>>sender`
  if msg.kind != bRec or msg.isProtocol:
    return nil
  l.body.evalBody(activation(obj, msg, self, sender))

method receive(l: Resolver, obj, msg, self, sender: Val): Val =
  if msg.isMsg(sResolve, 2):
    result = l.doit(msg.getChild(1), sender)

method receive(l: Cell, obj, msg, self, sender: Val): Val =
  if msg.isMsg(sGet, 1):
    return l.held
  if msg.isMsg(sPut, 2):
    let old = l.held
    l.held = msg.getChild(1)
    let id = obj.idOf
    if not id.isNil:
      l.held.enter
      let held = l.held
      emit bl"(changed $id >>held $old $held)"
    return l.held

method receive(l: ConstPlace, obj, msg, self, sender: Val): Val =
  if msg.isMsg(sGet, 1):
    return l.held
  if msg.isMsg(sPut, 2):
    refuse "nothing can be put into " & $l.held

method receive(l: SlotPlace, obj, msg, self, sender: Val): Val =
  if msg.isMsg(sGet, 1):
    result = l.obj.ownSlot(l.name)
    guard not result.isNil, "no slot " & $l.name & " in " & $l.obj
  elif msg.isMsg(sPut, 2):
    result = msg.getChild(1)
    l.obj.slotPut(l.name, result)

proc member*(frame, key: Val): Val =
  case frame.kind
  of bList, bRec:
    guard key.kind == bNum and key.num.isInt, "not an index: " & $key
    let i = key.num.toInt
    guard i in 0 ..< frame.len, "no member " & $key & " in " & $frame
    result = frame.getChild(i)
  of bDict:
    result = frame.dict.getOr(key, nil)
    guard not result.isNil, "no key " & $key & " in " & $frame
  else:
    refuse "no members in " & $frame

proc replaced*(frame, key, v: Val): Val =
  ## frame with the member at key now v
  case frame.kind
  of bList, bRec:
    discard frame.member(key)
    var items = frame.items
    items[key.num.toInt] = v
    Val.buildFrame(items, frame.kind, frame.mark)
  of bDict:
    var flat: seq[Val]
    var found = false
    for (k, x) in frame.dict.pairs:
      flat.add k
      if k == key:
        flat.add v
        found = true
      else:
        flat.add x
    guard found, "no key " & $key & " in " & $frame
    Val.buildFrame(flat, bDict, frame.mark)
  else:
    refuse "no members in " & $frame

method receive(l: AtPlace, obj, msg, self, sender: Val): Val =
  ## a value doesn't change, so a put builds the frame anew and puts it
  ## where the frame was
  if msg.isMsg(sGet, 1):
    result = l.target.get.member(l.key)
  elif msg.isMsg(sPut, 2):
    result = msg.getChild(1)
    l.target.put l.target.get.replaced(l.key, result)

method receive(l: LayerPlace, obj, msg, self, sender: Val): Val =
  if msg.isMsg(sGet, 1):
    let found = l.obj.layerNamed(l.head)
    result = if found.isNil: null else: found.mold
  elif msg.isMsg(sPut, 2):
    result = msg.getChild(1)
    if result.kind == bNil:
      l.obj.dropLayer(l.head)
    else:
      guard result.kind == bRec and result.getChild(0) == l.head,
        $result & " isn't a " & $l.head & " layer"
      l.obj.putLayer(result)

method receive(l: LayersPlace, obj, msg, self, sender: Val): Val =
  if msg.isMsg(sGet, 1):
    result = l.obj.layerForms
  elif msg.isMsg(sPut, 2):
    result = msg.getChild(1)
    guard result.kind == bSet, "layers are a set: " & $result
    var heads: seq[Val]
    for form in result.children:
      guard form.kind == bRec, "not a layer: " & $form
      heads.add form.getChild(0)
    var drop: seq[Val]
    for each in l.obj.layers:
      let head = each.headOf
      if not (each of Identity) and not head.isNil and head notin heads:
        drop.add head
    for head in drop:
      l.obj.dropLayer(head)
    for form in result.children:
      l.obj.putLayer(form)

# ================
# Writing and reading what only the kernel knows
# ================

method mold(l: Slots): Val =
  var flat: seq[Val]
  for (name, held) in l.table.pairs:
    flat.add name
    flat.add held
  let slots = Val.buildFrame(flat, bDict, false)
  bl"(slots $slots)"

proc readSlots(v: Val): Slots {.reader.} =
  matchValue v:
  of "(slots $d)":
    if d.kind == bDict:
      var table: SortedTable[Val, Val]
      for (k, x) in d.dict.pairs:
        table[k] = x
      return newSlots(table)
  else: discard

method mold(l: Native): Val =
  let name = headSym(l.name)
  bl"(native $name)"

proc readNative(v: Val): Native {.reader.} =
  matchValue v:
  of "(native $name)":
    if name.kind == bSym:
      let doit = natives.getOrDefault(name.text)
      if not doit.isNil:
        return newNative(name.text, doit)
  else: discard

method mold(l: Resolver): Val =
  let name = headSym(l.name)
  bl"(resolver $name)"

proc readResolver(v: Val): Resolver {.reader.} =
  matchValue v:
  of "(resolver $name)":
    if name.kind == bSym:
      let doit = resolvers.getOrDefault(name.text)
      if not doit.isNil:
        return newResolver(name.text, doit)
  else: discard

proc isParams(v: Val): bool =
  if v.kind != bList:
    return false
  for each in v.children:
    if each.kind != bSym:
      return false
  true

method mold(l: Fn): Val =
  let
    params = l.params
    body = l.body
  bl"(fn $params @body)"

proc readFn(v: Val): Fn {.reader.} =
  matchValue v:
  of "(fn $params &body)":
    if params.isParams:
      return newFn(params, body)
  else: discard

method mold(l: Op): Val =
  let body = l.body
  bl"(op @body)"

proc readOp(v: Val): Op {.reader.} =
  matchValue v:
  of "(op &body)": newOp(body)
  else: nil

{.pop.}

# ================
# Natives
# ================

proc docComment(def: NimNode): string =
  let body = def.body
  if body.kind == nnkStmtList and body.len > 0 and body[0].kind == nnkCommentStmt:
    result = body[0].strVal

macro native*(called: string, def: untyped) =
  ## `{.native: "NAME".}` on `proc p(msg, self, sender: Val): Val` makes p
  ## the native `(native NAME)` reads as. Its doc comment is its doc
  let
    p = def.name
    doc = newLit(def.docComment)
  def.addPragma nnkExprColonExpr.newTree(ident"raises",
    nnkBracket.newTree(bindSym"BasslineError"))
  quote do:
    `def`
    natives[`called`] = `p`
    nativeDocs[`called`] = `doc`

macro resolver*(called: string, def: untyped) =
  ## `{.resolver: "NAME".}` on `proc p(form, scope: Val): Val` makes p the
  ## scheme NAME, answering the place a form headed by it names
  let p = def.name
  def.addPragma nnkExprColonExpr.newTree(ident"raises",
    nnkBracket.newTree(bindSym"BasslineError"))
  quote do:
    `def`
    resolvers[`called`] = `p`

proc args*(msg, sender: Val): seq[Val] {.raises: [BasslineError].} =
  ## msg's arguments, each evaluated where it was sent from
  for i in 1 ..< msg.len:
    result.add msg.getChild(i).eval(sender)
