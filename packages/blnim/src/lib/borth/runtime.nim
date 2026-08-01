{.experimental: "strictFuncs".}
import std/[tables, deques]
import pkg/core
import pkg/lib/print
export tables, deques

type
  Primitive* = proc(rt: var Runtime)

  WordKind* = enum
    wPrim ## native code
    wQuote ## a stored quotation
    wCell ## a slot holding one value

  Word* = ref object
    ## A word is logically a dictionary:
    ## The native object slots are its reserved entries:
    ## 
    ## (evaluator, value, traits)
    ## 
    ## `meta` holds the open ones, and `bindingView` speaks
    ## the whole as one dict
    protected*: bool
    meta*: Value ## open keyed bindings; a dict when present
    case kind*: WordKind
    of wPrim:
      prim*: Primitive
    of wQuote:
      body*: Value
    of wCell:
      value*: Value

  FrameKind* = enum
    fCode ## a call body
    fExpand ## a macro expansion
    fPush ## restores a saved value when reached (for dip)
    fEach ## iterate content for effect
    fMap ## iterate content collect under a max height

  Frame* = object
    case kind*: FrameKind
    of fCode, fExpand:
      body*: Value
      ip*: int
    of fPush:
      saved*: Value
    of fEach, fMap:
      coll*: Value
      quote*: Value
      idx*: int ## next element, or the entry ordinal for dicts
      base*: int ## data-stack height before this iteration's inputs
      collected*: seq[Value]

  Runtime* = object
    stack*: seq[Value]
    input*: Deque[Value]
    words*: Table[Value, Word]
    frames*: seq[Frame]
    spent*: int ## fuel used so far
    maxDepth*: int ## control-stack ceiling

  RuntimeError* = object of CatchableError

template fail*(msg: string) =
  raise newException(RuntimeError, msg)

const DefaultMaxDepth = 200_000

func initRuntime*(maxDepth = DefaultMaxDepth): Runtime =
  Runtime(
    stack: @[],
    input: initDeque[Value](),
    words: initTable[Value, Word](),
    frames: @[],
    maxDepth: maxDepth,
  )

func primWord*(prim: Primitive, protected = true): Word =
  Word(kind: wPrim, prim: prim, protected: protected)

func quoteWord*(body: sink Value, protected = false): Word =
  Word(kind: wQuote, body: body, protected: protected)

func cellWord*(value: sink Value = Nil, protected = false): Word =
  Word(kind: wCell, value: value, protected: protected)

# probing ================

proc done*(rt: Runtime): bool =
  rt.frames.len == 0 and rt.input.len == 0

proc height*(rt: Runtime): int =
  rt.stack.len

proc isDefined*(rt: Runtime, key: Value): bool =
  rt.words.hasKey key

proc charge*(rt: var Runtime, n = 1) =
  ## Primitive for gauging compute costs.
  ## Each primitive has a cost associated with it.
  rt.spent += n

# data stack ================

proc push*(rt: var Runtime, v: varargs[Value]) =
  rt.stack.add v

proc pop*(rt: var Runtime): Value =
  if rt.height == 0:
    fail "pop: stack underflow"
  rt.stack.pop

# runtime input ================

proc feedValue*(rt: var Runtime, v: sink Value) =
  rt.input.addLast v
proc feedValue*(rt: var Runtime, vals: sink seq[Value]) =
  for v in vals:
    rt.feedValue v

proc feedFirst*(rt: var Runtime, v: sink Value) =
  rt.input.addFirst v
proc feedFirst*(rt: var Runtime, vals: sink seq[Value]) =
  for v in vals:
    rt.feedFirst v

proc readValue*(rt: var Runtime): Value =
  ## reads the next value from the topmost source.
  ## 
  ## A call body is a source for the words within it
  ## A macro expansion is transparent
  ## The input deque is the bottom source. 
  ## A read that bottoms out on the drained deque is a refusal.
  for i in countdown(rt.frames.high, 0):
    if rt.frames[i].kind == fCode:
      if rt.frames[i].ip < rt.frames[i].body.items.len:
        result = rt.frames[i].body.items[rt.frames[i].ip]
        inc rt.frames[i].ip
        return
  if rt.input.len == 0:
    fail "read: input exhausted"
  rt.input.popFirst

# word definitions ================

proc define*(rt: var Runtime, key: Value, word: sink Word) =
  if not key.marked:
    fail "define: key must be marked"
  if rt.isDefined key:
    fail "define: key already defined: " & $key
  rt.words[key] = word

proc define*(rt: var Runtime, key: string, word: sink Word) =
  rt.define(sym(key).mark(true), word)

proc defineMacro*(rt: var Runtime, key: Value, word: sink Word) =
  ## macros are bound under unmarked values so we can use & reference
  ## without marking. This is purely for lowering keystrokes
  ## and shouldn't be used in all cases!
  ## 
  ## I will probably expand this to include things other than
  ## symbols later.
  if key.marked:
    fail "defineMacro: key cannot be marked"
  if not key.isKind(bSym):
    fail "defineMacro: key must be a symbol"
  if rt.isDefined key:
    fail "defineMacro: key already defined: " & $key
  rt.words[key] = word

proc defineMacro*(rt: var Runtime, key: string, word: sink Word) =
  rt.defineMacro(sym(key), word)

proc primitive*(rt: var Runtime, key: string, prim: Primitive) =
  rt.define(key, primWord(prim))

proc undef*(rt: var Runtime, key: Value, force = false) =
  if not rt.isDefined key:
    fail "undef: no definition for " & $key
  if rt.words[key].protected and not force:
    fail "undef: " & $key & " is protected"
  rt.words.del key

proc undef*(rt: var Runtime, key: string, force = false) =
  rt.undef(sym(key).mark(true), force)

# bindings as dictionaries ================

const Reserved = [sym"evaluator", sym"value", sym"traits"]

proc bindingView*(w: Word): Value =
  var es: seq[Entry]
  case w.kind
  of wPrim:
    es.add (sym"evaluator", sym"primitive")
  of wQuote:
    es.add (sym"evaluator", sym"quote")
    es.add (sym"value", w.body)
  of wCell:
    es.add (sym"evaluator", sym"cell")
    es.add (sym"value", w.value)
  if w.protected:
    es.add (sym"traits", set(sym"protected"))
  if w.meta.isKind(bDict):
    for p in pairIndex(w.meta.ravel):
      es.add (w.meta.ravel[p.key], w.meta.ravel[p.val])
  dict(es)

proc bindingOf*(rt: Runtime, key: Value): Value =
  if not rt.isDefined(key):
    fail "binding: no word under " & $key
  bindingView(rt.words[key])

proc annotate*(rt: var Runtime, key: Value, patch: Value) =
  ## merge open (non-reserved) bindings onto a word
  ## with a lww merge on keys.
  ## 
  ## This will refuse to bind reserved entries.
  ## So don't do that!
  if not patch.isKind(bDict):
    fail "annotate: a patch is a dict"
  if not rt.isDefined(key):
    fail "annotate: no word under " & $key
  for p in pairIndex(patch.ravel):
    if patch.ravel[p.key] in Reserved:
      fail "annotate: " & $patch.ravel[p.key] & " is not open"
  var m = rt.words[key].meta
  if not m.isKind(bDict):
    var empty: seq[Entry]
    m = dict(empty)
  for p in pairIndex(patch.ravel):
    m = put(m, patch.ravel[p.key], patch.ravel[p.val])
  rt.words[key].meta = m

proc dictionaryOf*(rt: Runtime): Value =
  var es: seq[Entry]
  for k, w in rt.words:
    es.add (k, bindingView(w))
  dict(es)

# machinery ================

proc pushFrame(rt: var Runtime, f: sink Frame) =
  if rt.frames.len >= rt.maxDepth:
    fail "call depth past " & $rt.maxDepth
  rt.frames.add f

proc doQuote*(rt: var Runtime, quote: sink Value) =
  ## evaluate a quotation
  if not quote.isKind(bList):
    fail "do: requires a list"
  rt.pushFrame Frame(kind: fCode, body: quote, ip: 0)

proc doDip*(rt: var Runtime, saved: sink Value, quote: sink Value) =
  ## X [P] -> ... X : 
  ## 
  ## run P with X parked on the control stack
  if not quote.isKind(bList):
    fail "dip: requires a list"
  rt.pushFrame Frame(kind: fPush, saved: saved)
  rt.pushFrame Frame(kind: fCode, body: quote, ip: 0)

func contentLen(coll: Value): int =
  ## how many content elements a loop visits
  case coll.kind
  of bList, bSet: coll.ravel.len
  of bRecord: coll.ravel.len - 1
  of bDict: pairLen(coll.ravel)
  else: 0

proc doLoop*(rt: var Runtime, coll: sink Value, quote: sink Value, collecting: bool) =
  ## schedules an iteration over a frame's content.
  ## 
  ## For dicts each entry pushes key then value.
  ## 
  ## when used with map this will hold the quote to 
  ## a height contract and rebuilds the same frame.
  ## 
  ## when used with each this will leave the stack to the quote.
  if not coll.isFrame:
    fail "each: not a frame"
  if not quote.isKind(bList):
    fail "each: quote must be a list"
  if collecting:
    rt.pushFrame Frame(kind: fMap, coll: coll, quote: quote, idx: 0, base: 0)
  else:
    rt.pushFrame Frame(kind: fEach, coll: coll, quote: quote, idx: 0, base: 0)

proc rebuilt(coll: Value, collected: sink seq[Value]): Value =
  ## the same frame kind from mapped content
  case coll.kind
  of bList:
    list(collected, coll.marked)
  of bRecord:
    var xs = @[coll.head]
    xs.add collected
    record(xs, coll.marked)
  of bSet:
    set(collected, coll.marked)
  of bDict:
    var es = newSeqOfCap[Entry](pairLen(collected))
    for p in pairIndex(collected):
      es.add (collected[p.key], collected[p.val])
    try:
      dict(es, coll.marked)
    except ValueError as e:
      fail "map: " & e.msg
  else:
    coll # unreachable

proc eval*(rt: var Runtime, v: sink Value) =
  ## When a value is defined, it will execute it's word.
  ## "define!" only defines marked values and never unmarked ones.
  ## So unless a value is marked we don't have to look it up for execution.
  ## 
  ## When a defined value is evaluted we execute it.
  ## When an unmarked value that's not defined is evaluated,
  ## we just push it to the data-stack.
  ## Marked lists not defined are implicit docol invocations.
  ## And a marked symbol that's not defined refuses as "idk".
  ## 
  rt.charge()
  if (v.marked or v.isKind(bSym)) and rt.words.hasKey(v):
    let w = rt.words[v]
    case w.kind
    of wPrim:
      w.prim(rt)
    of wQuote:
      if v.marked:
        rt.pushFrame Frame(kind: fCode, body: w.body, ip: 0)
      else:
        rt.pushFrame Frame(kind: fExpand, body: w.body, ip: 0)
    of wCell:
      rt.push w.value
  elif v.marked:
    if v.isKind(bList):
      rt.pushFrame Frame(kind: fCode, body: v, ip: 0)
    else:
      fail "eval: an instruction I don't know: " & $v
  else:
    rt.push v

proc stepLoop(rt: var Runtime, ti: int) =
  rt.charge()
  let collecting = rt.frames[ti].kind == fMap
  let isDict = rt.frames[ti].coll.kind == bDict
  let outN = if isDict: 2 else: 1
  # harvest the iteration that just finished
  if collecting and rt.frames[ti].idx > 0:
    let base = rt.frames[ti].base
    if rt.height != base + outN:
      fail "map: the quote left " & $(rt.height - base) & " values, wanted " & $outN
    if isDict:
      let v = rt.pop
      let k = rt.pop
      rt.frames[ti].collected.add k
      rt.frames[ti].collected.add v
    else:
      rt.frames[ti].collected.add rt.pop
  # done?
  let n = contentLen(rt.frames[ti].coll)
  if rt.frames[ti].idx >= n:
    if collecting:
      let r = rebuilt(rt.frames[ti].coll, move rt.frames[ti].collected)
      rt.frames.setLen(ti)
      rt.push r
    else:
      rt.frames.setLen(ti)
    return
  # schedule the next iteration
  let i = rt.frames[ti].idx
  inc rt.frames[ti].idx
  rt.frames[ti].base = rt.height
  if isDict:
    let p = pair(i)
    rt.push rt.frames[ti].coll.ravel[p.key]
    rt.push rt.frames[ti].coll.ravel[p.val]
  elif rt.frames[ti].coll.kind == bRecord:
    rt.push rt.frames[ti].coll.ravel[i + 1]
  else:
    rt.push rt.frames[ti].coll.ravel[i]
  let quote = rt.frames[ti].quote
  rt.pushFrame Frame(kind: fCode, body: quote, ip: 0)

proc step*(rt: var Runtime): bool =
  ## one unit of work, returns false when idle.
  ## The control stack is data so we have tail calls
  ## and avoid blowing up the host stack.
  if rt.frames.len > 0:
    let ti = rt.frames.high
    case rt.frames[ti].kind
    of fPush:
      rt.charge()
      let v = move rt.frames[ti].saved
      rt.frames.setLen(ti)
      rt.push v
    of fCode, fExpand:
      if rt.frames[ti].ip >= rt.frames[ti].body.items.len:
        rt.charge()
        rt.frames.setLen(ti) # an empty body
      else:
        let item = rt.frames[ti].body.items[rt.frames[ti].ip]
        inc rt.frames[ti].ip
        if rt.frames[ti].ip >= rt.frames[ti].body.items.len:
          rt.frames.setLen(ti) # eager pop: tail position
        rt.eval(item)
    of fEach, fMap:
      rt.stepLoop(ti)
    true
  elif rt.input.len > 0:
    rt.eval(rt.input.popFirst)
    true
  else:
    false

proc pump*(rt: var Runtime, quantum: int): int =
  ## Runs at most `quantum` units of fuel and returns what was spent.
  let start = rt.spent
  while rt.spent - start < quantum and rt.step():
    discard
  rt.spent - start

proc run*(rt: var Runtime) =
  while rt.step():
    discard