## An image written down and read back. A snapshot is one value,
## `(image {root: ID at: N objects: {ID: {FORM …} …} lost: [ID …]})`: every
## object reachable from the root, each once under its id, as the set of
## how its layers are written. Objects name each other by `(object ID)`, so
## sharing and cycles read back as they were. `at` is the number of the
## last log entry the snapshot holds, and `lost` the objects that carried a
## layer with no written form, left out.

import std/algorithm
import core

refuseWith BasslineError

useValue Val

{.push raises: [BasslineError].}

let
  sNative = headSym"native"
  sResolverHead = headSym"resolver"

proc written(obj: Val, lost: var bool): Val =
  ## the set of how obj's layers are written, its Identity aside. lost says
  ## whether one of them has no written form
  var forms: seq[Val]
  for each in obj.layers:
    if each of Identity:
      continue
    let form = each.mold
    if form.isNil:
      lost = true
    else:
      forms.add form
  setOf(forms)

proc snapshot*(at = 0): Val =
  ## every object reachable from the root, each once, as how its layers are
  ## written. An object found without an id is given one, which enters it
  ## into the image
  guard not image.root.isNil, "an image with no root"
  var
    seen: Table[string, Val]
    order: seq[(Val, Val)]
    lost: seq[Val]
    todo = @[image.root]
  while todo.len > 0:
    let obj = todo.pop
    if obj.idOf.isNil:
      obj.identify
    let id = obj.idOf
    if id.bytes in seen:
      continue
    var lostOne = false
    let forms = obj.written(lostOne)
    seen[id.bytes] = obj
    order.add (id, forms)
    if lostOne:
      lost.add id
    for each in forms.walk:
      if each.isObject and not each.same(obj):
        let other = each.idOf
        if other.isNil or other.bytes notin seen:
          todo.add each
  order.sort(proc(a, b: (Val, Val)): int = cmp(a[0], b[0]))
  var flat: seq[Val]
  for (id, forms) in order:
    flat.add id
    flat.add forms
  let
    objects = Val.buildFrame(flat, bDict, false)
    root = image.root.idOf
  if lost.len == 0:
    result = bl"(image {root: $root at: $at objects: $objects})"
  else:
    lost.sort(cmp)
    result = bl"(image {root: $root at: $at objects: $objects lost: [@lost]})"

proc missingNative(forms: Val) =
  ## refuses a form naming a native or scheme the host lacks, by its name
  for form in forms.children:
    if form.kind == bRec and form.len == 2 and form.getChild(1).kind == bSym:
      let
        head = form.getChild(0)
        name = form.getChild(1).text
      if head == sNative:
        guard name in natives, "no native named " & name
      elif head == sResolverHead:
        guard name in resolvers, "no scheme named " & name

proc restore*(snap: Val): Val =
  ## a fresh image holding what snap wrote: a bare object for each id, then
  ## each filled from its written layers. Answers the root. The image hears
  ## no listeners until some are added
  let written = fromCE(snap.ce)
  var
    rootId, objects: Val
  matchValue written:
  of "(image $d)":
    guard d.kind == bDict, "not an image: " & $snap
    rootId = d.dict.getOr(headSym"root", nil)
    objects = d.dict.getOr(headSym"objects", nil)
  else: refuse "not an image: " & $snap
  guard not rootId.isNil and rootId.kind == bBytes, "an image names its root"
  guard not objects.isNil and objects.kind == bDict, "an image holds its objects"
  for (_, forms) in objects.dict.pairs:
    forms.missingNative
  freshImage()
  for (id, _) in objects.dict.pairs:
    guard id.kind == bBytes, "an object's id is bytes: " & $id
    discard id.placeholder
  for (id, forms) in objects.dict.pairs:
    id.byId.fillObject(forms)
  result = rootId.byId
  image.root = result

proc atOf*(snap: Val): int =
  ## the last log entry snap holds
  matchValue snap:
  of "(image $d)":
    let at = d.dict.getOr(headSym"at", nil)
    if not at.isNil and at.kind == bNum and at.num.isInt:
      result = at.num.toInt
  else: discard

proc saveImage*(path: string, at = 0) =
  ## the snapshot as CE to path, and as text to path & ".bl"
  let snap = snapshot(at)
  try:
    writeFile(path, snap.ce)
    writeFile(path & ".bl", $snap & "\n")
  except IOError as e:
    refuse "can't write " & path & ": " & e.msg

proc loadImage*(path: string): tuple[root: Val, at: int] =
  ## the image path holds, restored, and the last log entry it holds
  var bytes: string
  try:
    bytes = readFile(path)
  except IOError as e:
    refuse "can't read " & path & ": " & e.msg
  let snap = fromCE(bytes)
  (snap.restore, snap.atOf)

{.pop.}
