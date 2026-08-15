import std/macros

const
  valueQuestions = ["kind", "marked", "size", "payload", "els"]
  valueBuilders = ["null", "atom", "frame"]

proc questionDef(T: NimNode, name: string, v, body: NimNode): NimNode =
  case name
  of "kind":
    quote do:
      proc kind*(`v`: `T`): BlKind = `body`
  of "marked":
    quote do:
      proc marked*(`v`: `T`): bool = `body`
  of "size":
    quote do:
      proc size*(`v`: `T`): int = `body`
  of "payload":
    quote do:
      proc payload*(`v`: `T`): lent seq[byte] = `body`
  else:
    quote do:
      proc els*(`v`: `T`): lent seq[`T`] = `body`

proc builderDef(T: NimNode, name: string, params: seq[NimNode], body: NimNode): NimNode =
  case name
  of "null":
    let marked = params[0]
    quote do:
      proc null*(_: typedesc[`T`], `marked`: bool = false): `T` = `body`
  of "atom":
    let (payload, kind, marked) = (params[0], params[1], params[2])
    quote do:
      proc atom*(_: typedesc[`T`], `payload`: openArray[byte],
        `kind`: Atoms = bNum, `marked`: bool = false): `T` = `body`
  else:
    let (els, kind, marked) = (params[0], params[1], params[2])
    quote do:
      proc frame*(_: typedesc[`T`], `els`: sink seq[`T`],
        `kind`: Frames = bList, `marked`: bool = false): `T` = `body`

proc refusalBody(tname, what: string): NimNode =
  let msg = tname & " does not answer " & what
  quote do:
    refuse `msg`

macro defvalue*(T: untyped, body: untyped): untyped =
  ## defines a Value implementation for an existing type T.
  ## sections are `name(params): body` — questions kind/marked/size/
  ## payload/els and constructors null/atom/frame. missing sections
  ## default to raise and refuse.
  ## `==` and `hash` are always generated as concrete procs
  ## routed through cmp/hashValue
  result = newStmtList()
  var seen: seq[string]
  for section in body:
    if macros.kind(section) == nnkCommentStmt: continue
    if macros.kind(section) notin {nnkCall, nnkCommand} or section.len < 2 or
        macros.kind(section[^1]) != nnkStmtList:
      error("defvalue: expected `name(params): body`", section)
    let name = $section[0]
    if name in seen:
      error("defvalue: duplicate section '" & name & "'", section)
    var params: seq[NimNode]
    for i in 1 ..< section.len - 1:
      params.add section[i]
    let sbody = section[^1]
    if name in valueQuestions:
      if params.len != 1:
        error("defvalue: " & name & " takes one parameter (the value)", section)
      result.add questionDef(T, name, params[0], sbody)
    elif name in valueBuilders:
      let want = if name == "null": 1 else: 3
      if params.len != want:
        error("defvalue: " & name & " takes " & $want & " parameters", section)
      result.add builderDef(T, name, params, sbody)
    else:
      error("defvalue: unknown section '" & name &
        "' (kind, marked, size, payload, els, null, atom, frame)", section)
    seen.add name

  let tname = repr(T)
  for name in valueQuestions:
    if name notin seen:
      result.add questionDef(T, name, ident"v", refusalBody(tname, name))
  for name in valueBuilders:
    if name notin seen:
      let params =
        if name == "null": @[ident"marked"]
        elif name == "atom": @[ident"payload", ident"kind", ident"marked"]
        else: @[ident"els", ident"kind", ident"marked"]
      result.add builderDef(T, name, params, refusalBody(tname, name))

  let eq = quote do:
    proc eqValue*(a, b: `T`): bool =
      cmp(a, b) == 0
  eq[0] = nnkPostfix.newTree(ident"*", nnkAccQuoted.newTree(ident"=="))
  result.add eq
  result.add quote do:
    proc hash*(a: `T`): Hash =
      hashValue(a)