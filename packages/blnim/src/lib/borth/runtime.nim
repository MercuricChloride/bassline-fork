include pkg/prelude
import std/[tables, deques]
import pkg/core
import pkg/lib/print
export tables, deques

type
  Primitive* = proc(rt: var Runtime)

  WordKind* = enum wPrim, wQuote, wCell

  Word* = ref object
    ## A word is logically a dictionary:
    ## The native object slots are its reserved entries:
    ##
    ## (evaluator, value, traits)
    ##
    ## `meta` holds the open ones, and `bindingView` speaks
    ## the whole as one dict
    protected*: bool
    meta*: Table[Value, Value]
    case kind*: WordKind
    of wPrim:
      prim*: Primitive
    of wQuote, wCell:
      value*: Value

  FrameKind* = enum
    fCode ## a call body
    fExpand ## a macro expansion
    fPush ## restores a saved value when reached (for dip)
    fEach ## iterate content for effect
    fMap ## iterate content collecting into an open frame

  Frame* = object
    ## Bodies and iteration sources are OpenFrames owned by the frame.
    ## The naming convention for this is subpar. I apologize dear reader
    case kind*: FrameKind
    of fCode, fExpand:
      body*: OpenFrame
      ip*: int
    of fPush:
      saved*: Value
    of fEach, fMap:
      src*: OpenFrame
      quote*: Value
      idx*: int ## next element, or the entry ordinal for dicts
      base*: int ## data-stack height before this iteration's inputs
      dest*: OpenFrame ## fMap's harvest; inert for fEach

  Runtime* = object
    stack*: seq[Value] ## the main data stack
    frames*: seq[Frame]
    input*: Deque[Value]
    words*: Table[Value, Word]
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
  Word(kind: wQuote, value: body, protected: protected)

func cellWord*(value: sink Value = Nil, protected = false): Word =
  Word(kind: wCell, value: value, protected: protected)

# probing ================

func done*(rt: Runtime): bool =
  rt.frames.len == 0 and rt.input.len == 0

func height*(rt: Runtime): int =
  rt.stack.len

func isDefined*(rt: Runtime, key: Value): bool =
  rt.words.hasKey key

func charge*(rt: var Runtime, n = 1) =
  ## Primitive for gauging compute costs.
  ## Each primitive has a cost associated with it.
  rt.spent += n

# stack manipulation ================

func push*(rt: var Runtime, v: sink Value) =
  rt.stack.add v

func push*(rt: var Runtime, vs: varargs[Value]) =
  rt.stack.add vs

func pop*(rt: var Runtime): Value =
  if rt.height == 0:
    fail "pop: stack underflow"
  rt.stack.pop

# runtime input ================

func feedValue*(rt: var Runtime, v: sink Value) =
  rt.input.addLast v
func feedValue*(rt: var Runtime, vals: seq[Value]) =
  for v in vals:
    rt.feedValue v

func feedFirst*(rt: var Runtime, v: sink Value) =
  rt.input.addFirst v
func feedFirst*(rt: var Runtime, vals: sink seq[Value]) =
  for v in vals:
    rt.feedFirst v

func readValue*(rt: var Runtime): Value =
  ## reads the next value from the topmost source.
  ##
  ## A call body is a source for the words within it
  ## A macro expansion is transparent
  ## The input deque is the bottom source.
  ## A read that bottoms out on the drained deque is a refusal.
  for i in countdown(rt.frames.high, 0):
    if rt.frames[i].kind == fCode:
      let f: var Frame = rt.frames[i]
      if f.ip < f.body.len:
        result = f.body.take(f.ip)
        inc f.ip
        return
  if rt.input.len == 0:
    fail "read: input exhausted"
  rt.input.popFirst

# word definitions ================

func define*(rt: var Runtime, key: Value, word: sink Word) =
  if not key.marked:
    fail "define: key must be marked"
  if rt.isDefined key:
    fail "define: key already defined: " & $key
  rt.words[key] = word

func define*(rt: var Runtime, key: string, word: sink Word) =
  rt.define(sym(key).mark(true), word)

func defineMacro*(rt: var Runtime, key: Value, word: sink Word) =
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

func defineMacro*(rt: var Runtime, key: string, word: sink Word) =
  rt.defineMacro(sym(key), word)

func primitive*(rt: var Runtime, key: string, prim: Primitive) =
  rt.define(key, primWord(prim))

func undef*(rt: var Runtime, key: Value, force = false) =
  if not rt.isDefined key:
    fail "undef: no definition for " & $key
  if rt.words[key].protected and not force:
    fail "undef: " & $key & " is protected"
  rt.words.del key

func undef*(rt: var Runtime, key: string, force = false) =
  rt.undef(sym(key).mark(true), force)

# bindings as dictionaries ================

const Reserved = [sym"evaluator", sym"value", sym"traits"]

func bindingView*(w: Word): Value =
  var es = open(bDict)
  case w.kind
  of wPrim:
    es.add sym"evaluator", sym"primitive"
  of wQuote:
    es.add sym"evaluator", sym"quote"
    es.add sym"value", w.value
  of wCell:
    es.add sym"evaluator", sym"cell"
    es.add sym"value", w.value
  if w.protected:
    es.add sym"traits", set(sym"protected")
  for k, v in w.meta:
    es.add k, v
  es.close()

func bindingOf*(rt: Runtime, key: Value): Value =
  if not rt.isDefined(key):
    fail "binding: no word under " & $key
  bindingView(rt.words[key])

proc annotate*(rt: var Runtime, key: Value, patch: Value) =
  ## merge open (non-reserved) bindings onto a word
  ## This will refuse to bind reserved entries.
  ## So don't do that!
  if not patch.isKind(bDict):
    fail "annotate: a patch is a dict"
  if not rt.isDefined(key):
    fail "annotate: no word under " & $key
  for k, p in patch.pairs:
    if k in Reserved:
      fail "annotate: " & $k & " is not open"
  for k, p in patch.pairs:
    rt.words[key].meta[k] = p

func dictionaryOf*(rt: Runtime): Value =
  var es = open(bDict)
  for k, w in rt.words:
    es.add k, bindingView(w)
  es.close()

# machinery ================

func iterations(src: OpenFrame): int =
  ## how many content elements a loop visits: entries for a dict,
  ## children for everything else
  if src.kind == bDict:
    src.pairsLen
  else:
    src.childrenLen

func pushFrame(rt: var Runtime, f: sink Frame) =
  if rt.frames.len >= rt.maxDepth:
    fail "call depth past " & $rt.maxDepth
  rt.frames.add f

func doQuote*(rt: var Runtime, quote: sink Value) =
  ## evaluate a quotation
  if not quote.isKind(bList):
    fail "do: requires a list"
  rt.pushFrame Frame(kind: fCode, body: open(quote), ip: 0)

func doEach*(rt: var Runtime, coll: sink Value, quote: sink Value) =
  if not coll.isFrame:
    fail "each: not a frame"
  if not quote.isKind(bList):
    fail "each: quote must be a list"
  rt.pushFrame Frame(kind: fEach, src: open(coll), quote: quote, idx: 0, base: 0)

func doMap*(rt: var Runtime, coll: sink Value, quote: sink Value) =
  if not coll.isFrame:
    fail "map: not a frame"
  if not quote.isKind(bList):
    fail "map: quote must be a list"
  var f = Frame(kind: fMap, src: open(coll), quote: quote, idx: 0, base: 0)
  f.dest = open(f.src.kind, f.src.marked)
  if f.src.kind == bRecord:
    f.dest.add f.src.take(0)
  rt.pushFrame f

func doDip*(rt: var Runtime, saved: sink Value, quote: sink Value) =
  rt.pushFrame Frame(kind: fPush, saved: saved)
  rt.pushFrame Frame(kind: fCode, body: open(quote), ip: 0)

proc eval*(rt: var Runtime, v: sink Value) =
  ## When a value is defined, it will execute it's word.
  ## "define!" only defines marked values and never unmarked ones.
  ## So unless a value is marked we don't have to look it up for execution.
  ##
  ## With a defined marked value we execute it.
  ## When an unmarked value that's not defined is evaluated,
  ## we just push it to the data-stack.
  ## Marked lists not defined are implicit docol invocations.
  ## And a marked symbol that's not defined refuses as "idk".
  rt.charge()
  if (v.marked or v.isKind(bSym)) and rt.words.hasKey(v):
    let w = rt.words[v]
    case w.kind
    of wPrim:
      w.prim(rt)
    of wQuote:
      if v.marked:
        rt.pushFrame Frame(kind: fCode, body: open(w.value), ip: 0)
      else:
        rt.pushFrame Frame(kind: fExpand, body: open(w.value), ip: 0)
    of wCell:
      rt.push w.value
  elif v.marked:
    if v.isKind(bList):
      rt.pushFrame Frame(kind: fCode, body: open(v), ip: 0)
    else:
      fail "eval: idk what this is " & $v
  else:
    rt.push v

func scheduleIteration(rt: var Runtime, ti: int) =
  ## move the next element(s) to the stack and call the quote.
  ## The block is there because we take the values under the frame
  ## borrow, but the push reshapes the rt potentially invalidting it
  ## So this scopes the borrow so it ends and it's all good.
  var
    quote: OpenFrame
    a, b: Value
    isDict: bool
  block:
    let frame: var Frame = rt.frames[ti]
    if frame.src.kind == bDict:
      isDict = true
    quote = frame.quote.open()
    let i = frame.idx
    inc frame.idx
    frame.base = rt.height
    if isDict:
      a = frame.src.takeKey(i)
      b = frame.src.takeVal(i)
    else:
      a = frame.src.takeChild(i)
  rt.push a
  if isDict:
    rt.push b
  rt.pushFrame Frame(kind: fCode, body: quote, ip: 0)

func stepEach(rt: var Runtime, ti: int) =
  rt.charge()
  let frame: lent Frame = rt.frames[ti]
  if frame.idx >= iterations(frame.src):
    rt.frames.setLen(ti)
    return
  rt.scheduleIteration(ti)

func stepMap(rt: var Runtime, ti: int) =
  rt.charge()
  let (isDict, harvesting, base) = block:
    let frame: lent Frame = rt.frames[ti]
    (frame.src.kind == bDict, frame.idx > 0, frame.base)
  let outN = if isDict: 2 else: 1
  # harvest the iteration that just finished: the pops reshape the
  # stack, so they run before the frame borrow
  var k, v: Value
  if harvesting:
    if rt.height != base + outN:
      fail "map: the quote left " & $(rt.height - base) & " values, wanted " &
        $outN
    if isDict:
      v = rt.pop
      k = rt.pop
    else:
      v = rt.pop
  # the frame work clusters under one borrow; it ends before the
  # frames seq is reshaped
  var 
    d: OpenFrame
    finished = false
  block:
    let frame: var Frame = rt.frames[ti]
    if harvesting:
      if isDict:
        frame.dest.add(k, v)
      else:
        frame.dest.add v
    if frame.idx >= iterations(frame.src):
      d = move frame.dest
      finished = true
  if finished:
    rt.frames.setLen(ti)
    rt.push close d
    return
  rt.scheduleIteration(ti)

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
      var item: Value
      var state = 0 # 0 empty body, 1 read, 2 read at the tail
      block: # the borrow ends before the frames seq is reshaped
        let f: var Frame = rt.frames[ti]
        if f.ip < f.body.len:
          item = f.body.take(f.ip)
          inc f.ip
          state = if f.ip >= f.body.len: 2 else: 1
      case state
      of 0:
        rt.charge()
        rt.frames.setLen(ti) # an empty body
      of 2:
        rt.frames.setLen(ti) # eager pop: tail position
        rt.eval(item)
      else:
        rt.eval(item)
    of fEach:
      rt.stepEach(ti)
    of fMap:
      rt.stepMap(ti)
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