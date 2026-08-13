include pkg/prelude

import std/sets
import ./values

type ValuePred* = proc(v: Value): bool {.noSideEffect.}

# Two planes of operation:
#
# READERS take closed Values — reading is what closed values are
# for, and a ValuePred is noSideEffect, so it cannot mutate anything
# a walk borrows through.
#
# RESHAPERS take drafts and return drafts: open a frame, transform
# it, and the caller holds the door. They consume their inputs, so a
# raising callback destroys the in-flight draft (husks unreachable)
# and a capturing closure holds only a moved-from shell. Ops whose
# joins need canonical order demand it via canonicalize — a verifying
# scan when the draft came from a closed value, a real sort only
# when it was built by hand.

# ================ DEEP SEARCH ================
func seek(
    v: Value, pred: ValuePred, descendMarked: bool, res: var Value
): bool {.effectsOf: pred.} =
  if pred(v):
    res = v
    return true
  if not descendMarked and v.marked:
    return false
  if v.isFrame:
    for c in v.contents:
      if seek(c, pred, descendMarked, res):
        return true
  false

func find*(
    v: Value, pred: ValuePred, descendMarked = true
): Value {.effectsOf: pred.} =
  ## the first value in walk order that pred admits (v itself first),
  ## as an owned copy; nothing admitted refuses
  if not seek(v, pred, descendMarked, result):
    refuse "find: nothing admitted"

func walkInto(
    v: Value, pred: ValuePred, into: var OpenFrame, descendMarked: bool
) {.effectsOf: pred.} =
  if pred(v):
    into.add v
  if not descendMarked and v.marked:
    return
  if v.isFrame:
    for c in v.contents:
      walkInto(c, pred, into, descendMarked)

func findInto*(
    v: Value, pred: ValuePred, into: var OpenFrame, descendMarked = true
) {.effectsOf: pred.} =
  ## every value in walk order that pred admits, fed to a draft
  walkInto(v, pred, into, descendMarked)

func map*(
    src: sink OpenFrame, f: proc(x: sink Value): Value
): OpenFrame {.effectsOf: f.} =
  result = src
  if result.kind == bDict:
    for _, v in result.mpairs:
      v = f(move v)
  else:
    for x in result.mchildren:
      x = f(move x)

func filter*(
    src: sink OpenFrame, pred: proc(x: Value): bool
): OpenFrame {.effectsOf: pred.} =
  result = open(src.kind, src.marked)
  if src.len == 0: return
  case src.kind
  of bDict:
    for k, v in src.drainPairs:
      if pred(v):
        result.add(k, v)
  else:
    if src.kind == bRecord:
      result.add src.take(0)
    for x in src.drainChildren:
      if pred(x):
        result.add x

# ================ STRUCTURAL ALGEBRA ================

func merge*(a: var OpenFrame, b: sink OpenFrame) =
  ## keyed combination for dicts, union for sets: b feeds into a,
  ## the door judges
  if a.kind != b.kind:
    refuse "merge: frames must match"
  canonicalize(a)
  case a.kind
  of bSet:
    for v in b.drainChildren:
      a.add v
  of bDict:
    for (k, v) in b.drainPairs:
      a.add k, v
  else:
    refuse "merge: can only merge dicts & sets"

func merge*(a: var OpenFrame, b: sink Value) =
  merge(a, open(b))

func difference*(a, b: sink OpenFrame): OpenFrame =
  ## returns elements of a not in b
  ## this does set difference when a & b are sets
  ## this does key-based difference when a & b are dicts
  if a.kind != b.kind:
    refuse "difference: frames must match"
  var seen: HashSet[Value]
  case a.kind
  of bSet:
    result = open(bSet, a.marked)
    for x in b.drainChildren:
      seen.incl x
    for x in a.drainChildren:
      if x notin seen:
        result.add x
  of bDict:
    result = open(bDict, a.marked)
    for k, _ in b.drainPairs:
      seen.incl k
    for k, v in a.drainPairs:
      if k notin seen:
        result.add k, v
  else:
    refuse "difference: must be a set or a dict"

func symmetricDifference*(a, b: sink OpenFrame): OpenFrame =
  var inA, inB: HashSet[Value]
  case a.kind
  of bSet:
    result = open(bSet, a.marked)
    for x in a.drainChildren: inA.incl x
    for x in b.drainChildren: inB.incl x
    for x in inA -+- inB: result.add x
  of bDict:
    result = open(bDict, a.marked)
    for k, _ in a.drainPairs: inA.incl k
    for k, _ in b.drainPairs: inB.incl k
    let unique = inA -+- inB
    for k, v in a.drainPairs:
      if k in unique:
        result.add k, v
    for k, v in b.drainPairs:
      if k in unique:
        result.add k, v
  else:
    refuse "symmetricDifference: must be a set or a dict"

func `-+-`*(a, b: sink OpenFrame): OpenFrame =
  a.symmetricDifference(b)

func put*(a: sink OpenFrame, k, v: sink Value): OpenFrame =
  ## last wins for dict drafts; by index for positional drafts, the
  ## head included
  result = a
  case result.kind
  of bDict:
    var vv = v
    for bk, bv in result.mpairs:
      if bk == k:
        bv = move vv
        return
    result.add(k, move vv)
  of bList, bRecord:
    if k.kind != bNum:
      refuse "put: a positional frame takes a numeric key"
    var n: int
    try:
      n = k.num.parseInt()
    except ValueError:
      refuse "put: not an index"
    if n < 0 or n >= result.len:
      refuse "nothing under that index"
    result[n] = v
  of bSet:
    refuse "sets take union"

func keys*(src: sink OpenFrame): OpenFrame =
  if src.kind != bDict:
    refuse "not a dict"
  result = open(bSet, src.marked)
  for k, v in src.drainPairs:
    result.add k

func vals*(src: sink OpenFrame): OpenFrame =
  ## a dict draft's values as a set; same dict-wise judgment, and
  ## value collisions dedupe at the caller's close
  if src.kind != bDict:
    refuse "not a dict"
  result = open(bSet, src.marked)
  for k, v in src.drainPairs:
    result.add v

# ================ FRY ================

func holeIndex(t: Value, window: int): int =
  result = t.num.parseInt()
  if result == 0:
    refuse "0! names nothing"
  if abs(result) > window:
    refuse "a hole reaches past the window"

func fry*(t: Value, window: openArray[Value]): Value
  ## Factor style value templating.
  ## Unlike factor we don't utilize _ or @ as words
  ## for templating. Instead we use marked numbers
  ## in the template value representing the depth
  ## in the stack to bind.
  ##
  ## So with a stack: `BOTTOM [ a b c ] TOP`
  ## a is 3!, b is 2!, c is 1!
  ##
  ## If a number is negative this is a sign to splice
  ##
  ## So if `a` were a list, we would splice with `-3!`
  ##
  ## The substitution walks the template value only
  ## and isn't recursive

func entrySide(c: Value, window: openArray[Value]): Value =
  ## a dict key or value holds exactly one value: no splicing
  if c.isKind(bNum) and c.marked:
    let k = holeIndex(c, window.len)
    if k < 0:
      refuse "cannot splice into a dict entry"
    return window[^k]
  fry(c, window)

func fry*(t: Value, window: openArray[Value]): Value =
  if t.isKind(bNum) and t.marked:
    let k = holeIndex(t, window.len)
    if k < 0:
      refuse "nothing to splice into at the top"
    return window[^k]
  if not t.isFrame:
    return t

  case t.kind
  of bDict:
    var b = open(bDict, t.marked)
    for k, v in t.pairs:
      b.add(entrySide(k, window), entrySide(v, window))
    close b
  else:
    # the template walk is the spelling: a record's head is a slot too
    var b = open(t.kind, t.marked)
    for c in t.contents:
      if c.isKind(bNum) and c.marked:
        let k = holeIndex(c, window.len)
        if k > 0:
          b.add window[^k]
        else:
          let spliced = window[^(-k)]
          if not spliced.isFrame:
            refuse "a splice hole names a non-frame"
          for x in spliced.contents:
            b.add x
      else:
        b.add fry(c, window)
    close b

func fryReach*(t: Value): int =
  ## the deepest hole the template reaches
  if t.isKind(bNum) and t.marked:
    let k = t.num.parseInt()
    if k == 0:
      refuse "0! names nothing"
    return abs(k)
  if not t.isFrame:
    return 0
  for c in t.contents:
    result = max(result, fryReach(c))

func index*(v: Value, path: varargs[Value]): Value =
  result = v
  for step in path:
    result = result.at(step)

func putAt*(container: sink Value, value: sink Value, path: varargs[Value]): Value =
  case path.len
  of 0:
    refuse "putAt: empty path"
  of 1:
    container
      .open
      .put(path[0], value)
      .close
  else:
    var
      key = path[0]
      prev = container.at(key)
      tail = path[1..^1]
    container
      .open
      .put(key, prev.putAt(value, tail))
      .close

iterator enumerate*(v: Value): (Value, lent Value) {.closure.} =
  case v.kind
  of bDict:
    for (key, val) in v.pairs:
      yield (key, val)
  of bSet:
    for el in v.contents:
      yield (el, el)
  of bList, bRecord:
    var 
      i = 0
    for val in v.contents:
      yield (num(i), val)
      inc i
  else: discard

iterator contentPaths*(v: Value, path: seq[Value] = @[]): (seq[Value], lent Value) {.closure.} =
  for (key, val) in v.enumerate:
    let nextPath = path & key
    yield (nextPath, val)
    for (pat, el) in val.contentPaths:
      yield (nextPath & pat, el)

func similar*(a, b: Value): bool
  ## Checks to see if a is similar to b
  ## 
  ## The base case is atoms
  ## Two values are similar if:
  ## 1. kind(a) == kind(b)
  ## 2. marked(a) == marked(b)
  ## 
  ## when a is a list:
  ## 3. len(a) == len(b)
  ## 4. each pairwise element is similar
  ## 
  ## when a is a record:
  ## 3. len(a) == len(b)
  ## 5. head(a) == head(b)
  ## 4. each pairwise element is similar
  ## 
  ## when a is a set:
  ## 3. for each el of a is there a similar element in b
  ## 
  ## when a is a dict:
  ## 3. for each entry in a is there and entry with:
  ## - an EQUAL key
  ## - an SIMILAR val

func similarList(a, b: Value): bool =
  result = true
  let
      ac = a.contents()
      bc = b.contents()
  if ac.len != bc.len:
    return false
  for i in 0 ..< ac.len:
    if not similar(ac[i], bc[i]):
      return false

func similarSet(a, b: Value): bool =
  result = true
  for aEl in a.contents:
    block inner:
      for bEl in b.contents:
        if aEl.similar(bEl):
          break inner
      return false

func similarDict(a, b: Value): bool =
  result = true
  for (ak, av) in a.pairs:
    block inner:
      for (bk, bv) in b.pairs:
        if ak == bk and similar(av, bv):
          break inner
      return false

func similar*(a, b: Value): bool =
  if a.kind != b.kind:
    return false
  if a.marked != b.marked:
    return false
  case a.kind
  of bList:
    similarList(a, b)
  of bRecord:
    similarList(a, b) and a.head == b.head
  of bSet:
    similarSet(a, b)
  of bDict:
    similarDict(a, b)
  else:
    true

func classify*(value, shapes: Value): Value =
  if shapes.kind != bDict:
    refuse "classify: shapes must be a dict"
  var output = open(bSet)
  for name, shape in shapes:
    if value.similar(shape):
      output.add name
  output.close()

const HoleShape* = sym("hole", true)

iterator holes*(value: Value): (seq[Value], lent Value) =
  for (p, v) in value.contentPaths:
    if v.similar(HoleShape):
      yield (p, v)

func extract*(value, holey: Value): Value =
  var output = open(bDict)
  for (path, hole) in holey.holes:
    var
      val = value.index(path)
    block inner:
      for (k, v) in output.mpairs:
        if hole != k: continue
        if val == v: break inner
        refuse "extract: holes dont match"
      output.add(hole, val)
  output.close()

func inject*(holey: sink Value, bindings: Value): Value =
  if bindings.kind != bDict:
    refuse "inject: bindings must be a dict"
  var
    output = holey
    count: int
  for (path, hole) in holey.holes:
    let value = bindings.at(hole)
    output = output.putAt(value, path)
    inc count
  if count == 0:
    refuse "inject: expected a value with holes"
  return output

when isMainModule:
  import pkg/lib/blmacro
  let
    records = program:
      foo(bar, baz)
      something(other, entirely)
    someSets = program:
      { a, !b, "c" }
      { x, "y", !z }
    dicts = program:
      { foo: 123 }
      { foo: 456 }
    lists = program:
      [1, two, 3]
      [69, `four-twenty`, 420]

  echo similar(records[0], records[1])
  echo similar(someSets[0], someSets[1])
  echo similar(dicts[0], dicts[1])
  echo similar(lists[0], lists[1])

  let
    something = bl:
      { a: { b: 69 },
        b: 69 }
    another = bl:
      {
        a: {b: !b},
        b: !b
      }

  echo "something: ", something
  let bindings = something.extract(another)
  echo "bindings: ", bindings
  let bound = another.inject(bindings)
  echo "bound: ", bound

  let
    user = bl:
      user(!age, !name, !bio)
    feed = program:
      post(
        goose,
        date(8, 12, 2026),
        "this is a blog post example thing")
      log("all systems normal")
      msg(miso, goose, date(8, 13, 2026), "feed me")
      msg(miso, goose, date(8, 13, 2026), "meow")
      post(
        goose, 
        date(8, 13, 2026),
        "this is another post")

  const DateShape = bl: date(1, 2, 3)
  const Shapes = bl: {
    date: %DateShape,
    log: log("string"),
    post: post(author, %DateShape, "string"),
    msg: msg(source, target, %DateShape, "string")
  }

  const DateFields = bl: date(!month, !day, !year)
  const Fields = bl: {
    date: %DateFields,
    log: log(!msg),
    post: post(!author, %DateFields, !content),
    msg: msg(!source, !target, %DateFields, !content)
  }

  proc getFields*(v, shapes, fields: Value): Value =
    var output = open(bDict)
    for c in v.classify(shapes).contents:
      merge output, v.extract(fields.at c)
    output.close

  for x in feed:
    let c = x.classify(Shapes)
    echo "item: ", x
    echo "classified: ", c
    let diff = close(Shapes.open.keys -+- c.open)
    echo "not classified: ", diff
    echo "fields: ", x.getFields(Shapes, Fields)