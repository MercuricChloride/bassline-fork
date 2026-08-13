include pkg/prelude
import std/[algorithm, hashes]
import ./strflavors
export strflavors

type
  BlKind* = enum
    bNil   # nil
    bNum   # scalar types
    bText
    bSym
    bBytes
    bList  # frame types
    bRecord
    bDict
    bSet

  Value* = object
    marked: bool
    case kind: BlKind
    of bNil:
      discard
    of bNum:
      num: DecimalString
    of bText, bSym:
      text: Utf8String
    of bBytes:
      bytes: seq[byte]
    of bList, bRecord, bDict, bSet:
      els: seq[Value]

  Entry* = tuple[key: Value, val: Value]
    ## input sugar for dict construction; never a stored shape

  OpenFrame* = object
    ## A mutable move-only container
    ## that we can finalize & validate the invariants
    ## of the canonical encoding.
    ## `close` is a softer program level check that will
    ## massage slightly wrong data in a reasonable manner.
    ## Whereas `seal` will perform full strict validation
    ## and refuse any malformed or invalid data.
    kind: BlKind
    marked: bool
    els: seq[Value]

const Framish = {bList, bRecord, bDict, bSet}

template fail(msg: untyped) =
  raise newException(ValueError, msg)

template refuse*(msg: untyped) =
  ## I may like this name better, not 100% sure yet.
  ## So for now this is an alias for `fail`
  fail(msg)

proc `=copy`(dest: var OpenFrame, src: OpenFrame) {.error.}

# ================ FORWARD DECL ================

func cmp*(a, b: Value): int
func `==`*(a, b: Value): bool

# ================ RECOGNITION ================

func kind*(v: Value): BlKind =
  v.kind

func isKind*(v: Value, k: BlKind): bool =
  v.kind == k

func isKind*(v: Value, k: set[BlKind]): bool =
  k.contains(v.kind)

func isFrame*(v: Value): bool =
  v.isKind(Framish)

func marked*(v: Value): bool =
  v.marked

func tag*(value: Value): 1 .. 9 =
  ord(value.kind) + 1

# ================ SCALAR ACCESSORS ================

func num*(v: Value): lent DecimalString =
  if v.kind == bNum:
    return v.num
  fail "num: not a number"

func text*(v: Value): lent Utf8String =
  if v.kind in {bText, bSym}:
    return v.text
  fail "text: not text or a symbol"

func bytes*(v: Value): lent seq[byte] =
  if v.kind == bBytes:
    return v.bytes
  fail "bytes: not bytes"

func payloadLength*(value: Value): int =
  case value.kind
  of bNum: value.num.len
  of bText, bSym: value.text.len
  of bBytes: value.bytes.len
  else: 0

# ================ THE PLANES ================
# contents — the flat spelling, CE constituent order: a record's head
#            and a dict's keys are in it
# children — the logical children: contents, but a record's head
#            stays out
# pairs    — a dict spoken as its entries

func contents*(v: Value): lent seq[Value] =
  ## a frame's flat payload in CE order; for dicts this is k v k v
  if v.kind in Framish:
    return v.els
  fail "contents: not a frame"

iterator contents*(v: Value): lent Value =
  ## the constituents in CE order
  if v.kind notin Framish:
    fail "contents: not a frame"
  for i in 0 ..< v.els.len:
    yield v.els[i]

iterator children*(v: Value): lent Value =
  ## the logical children: a record's head stays out
  case v.kind
  of bList, bSet, bDict:
    for i in 0 ..< v.els.len:
      yield v.els[i]
  of bRecord:
    for i in 1 ..< v.els.len:
      yield v.els[i]
  else:
    fail "children: not a frame"

iterator pairs*(v: Value): (lent Value, lent Value) =
  ## a dict's entries in canonical key order
  if v.kind != bDict:
    fail "pairs: not a dict"
  var i = 0
  while i + 1 < v.els.len:
    yield (v.els[i], v.els[i + 1])
    i += 2

func pairsLen*(v: Value): int =
  if v.kind != bDict:
    fail "pairsLen: not a dict"
  v.els.len div 2

func head*(v: Value): lent Value =
  case v.kind
  of bList, bRecord:
    if v.els.len == 0:
      fail "head: an empty list has no head"
    return v.els[0]
  else:
    fail "head: must be a list or record"

# ================ LOOKUP ================
# `at` answers or refuses; `hasKey`/`contains` probe and never refuse.
# A miss is silence: there is nothing to hand back, so asking is
# refused and probing answers false — never a nil payload.

func dictValSlot(els: seq[Value], key: Value): int =
  ## the flat index of the value under `key`, or -1.
  ## Canonical key order makes this a binary search.
  var lo = 0
  var hi = els.len div 2 - 1
  while lo <= hi:
    let m = (lo + hi) div 2
    let c = cmp(els[2 * m], key)
    if c == 0:
      return 2 * m + 1
    if c < 0:
      lo = m + 1
    else:
      hi = m - 1
  -1

func setMemberSlot(els: seq[Value], x: Value): int =
  ## the flat index of member `x`, or -1; binary over canonical order
  var lo = 0
  var hi = els.len - 1
  while lo <= hi:
    let m = (lo + hi) div 2
    let c = cmp(els[m], x)
    if c == 0:
      return m
    if c < 0:
      lo = m + 1
    else:
      hi = m - 1
  -1

func at*(v: Value, key: Value): lent Value =
  ## dicts answer the value under `key`; positional frames take a
  ## numeric key as an index; sets answer with their own element.
  ## A miss refuses.
  case v.kind
  of bList, bRecord:
    if key.kind != bNum:
      fail "at: a positional frame takes a numeric key"
    var n: int
    try:
      n = key.num.parseInt()
    except ValueError:
      fail "at: not an index"
    if n < 0 or n >= v.els.len:
      fail "at: nothing under that index"
    return v.els[n]
  of bDict:
    let s = dictValSlot(v.els, key)
    if s < 0:
      fail "at: nothing under that key"
    return v.els[s]
  of bSet:
    let s = setMemberSlot(v.els, key)
    if s < 0:
      fail "at: not a member"
    return v.els[s]
  else:
    fail "at: not a frame"

func hasKey*(v: Value, key: Value): bool =
  ## does a dict hold an entry under `key`; false for everything else
  v.kind == bDict and dictValSlot(v.els, key) >= 0

func contains*(v: Value, x: Value): bool =
  ## shallow containment among the contents: heads and keys count.
  ## Canonical order makes set membership a binary search.
  if not v.isFrame:
    return false
  if v.kind == bSet:
    return setMemberSlot(v.els, x) >= 0
  for c in v.contents:
    if c == x:
      return true

# ================ HASHING ================

func hash*(v: Value): Hash =
  ## This is not a cryptographic hash!
  ##
  ## This is only used for things like tables & hash sets.
  ## Use lib/digest for cryptographic hashing
  var h: Hash = 0
  h = h !& hash(v.tag)
  h = h !& hash(v.marked)
  case v.kind
  of bNil:
    discard
  of bNum:
    h = h !& hash(string(v.num))
  of bText, bSym:
    h = h !& hash(string(v.text))
  of bBytes:
    h = h !& hash(v.bytes)
  of bList, bRecord, bSet, bDict:
    for c in v.contents:
      h = h !& hash(c)
  result = !$h

# ================ ORDERING ================

  ## A comparison that's faithful to a lexicographic CE byte order.
  ##
  ## The CE encoding gives all values a header byte like:
  ## [tag:4][mark:1][len:3]
  ##
  ## cmp does the same ordering by: tag, mark, payload length, payload
  ##
  ## NOTE!
  ##
  ## Because frames are delimited with 0xA0 and since
  ## that byte is > all other CE header bytes it means that:
  ## a shorter frame is > a longer frame

func cmp*(a, b: seq[byte]): int =
  for i in 0 ..< min(a.len, b.len):
    let c = cmp(a[i], b[i])
    if c != 0:
      return c
  cmp(a.len, b.len)

func cmp*(a, b: seq[Value]): int =
  for i in 0 ..< min(a.len, b.len):
    let c = cmp(a[i], b[i])
    if c != 0:
      return c
  # Note! This looks backwards, but when comparing frames
  # the end byte (0xA0) is > all other header bytes
  # so a > b if a is a prefix of b
  cmp(b.len, a.len)

func cmp*(a, b: Value): int =
  let byTag = cmp(a.tag, b.tag)
  if byTag != 0:
    return byTag

  let byMark = cmp(a.marked, b.marked)
  if byMark != 0:
    return byMark

  let byLen = cmp(a.payloadLength, b.payloadLength)
  if byLen != 0:
    return byLen

  case a.kind
  of bNil:
    0
  of bNum:
    cmp(a.num, b.num)
  of bText, bSym:
    cmp(a.text, b.text)
  of bBytes:
    cmp(a.bytes, b.bytes)
  of bList, bRecord, bSet, bDict:
    cmp(a.els, b.els)

func cmp(a, b: Entry): int =
  cmp(a.key, b.key)

func `==`*(a, b: Value): bool =
  cmp(a, b) == 0

func `>`*(a, b: Value): bool =
  cmp(a, b) > 0

func `>=`*(a, b: Value): bool =
  cmp(a, b) >= 0

func `<`*(a, b: Value): bool =
  cmp(a, b) < 0

func `<=`*(a, b: Value): bool =
  cmp(a, b) <= 0

# ================ MARK ================

func mark*(v: sink Value, marked: bool = true): Value =
  result = v
  result.marked = marked

# ================ CANONICALIZATION ================

func dedupSorted(xs: var seq[Value]) =
  ## drops repeats from an already sorted seq in place.
  var n = 0
  for i in 0 ..< xs.len:
    if n == 0 or xs[i] != xs[n - 1]:
      if n != i:
        xs[n] = move(xs[i])
      inc n
  xs.setLen(n)

func canonicalizePairs(els: var seq[Value]) =
  ## sorts a flat k v payload by key CE order; refuses a duplicate
  ## key like the decoder would. Zero copies: elements round-trip
  ## through the sort by move.
  if els.len mod 2 != 0:
    fail "dict: a payload alternates key, value"
  let n = els.len div 2
  if n < 2:
    return
  var es = newSeq[Entry](n)
  for i in 0 ..< n:
    es[i] = (move els[2 * i], move els[2 * i + 1])
  es.sort(cmp)
  for i in 1 ..< n:
    if cmp(es[i - 1].key, es[i].key) == 0:
      fail "dict: duplicate key"
  for i in 0 ..< n:
    els[2 * i] = move es[i].key
    els[2 * i + 1] = move es[i].val

# ================ OPEN FRAMES ================

func open*(kind: BlKind, marked = false): OpenFrame =
  ## the header moment: an empty draft of this frame kind
  if kind notin Framish:
    fail "open: not a frame kind"
  OpenFrame(kind: kind, marked: marked)

func open*(v: sink Value): OpenFrame =
  ## explode: the frame's kind, mark, and contents, ownership taken
  if v.kind notin Framish:
    fail "open: not a frame"
  OpenFrame(kind: v.kind, marked: v.marked, els: move v.els)

func kind*(b: OpenFrame): BlKind =
  b.kind

func marked*(b: OpenFrame): bool =
  b.marked
func `marked=`*(b: var OpenFrame, marked: bool) =
  b.marked = marked

func rekind*(b: var OpenFrame, kind: BlKind) =
  ## a draft can change what frame kind it is
  if kind notin Framish:
    fail "rekind: not a frame kind"
  b.kind = kind

func len*(b: OpenFrame): int =
  b.els.len

func `[]`*(b: OpenFrame, i: int): lent Value =
  b.els[i]

func `[]=`*(b: var OpenFrame, i: int, v: sink Value) =
  if i < 0 or i >= b.els.len:
    fail "[]=: nothing under that index"
  b.els[i] = v

func add*(b: var OpenFrame, v: sink Value) =
  b.els.add v

func add*(b: var OpenFrame, k, v: sink Value) =
  b.els.add k
  b.els.add v

func take*(b: var OpenFrame, i: int): Value =
  ## moves an element out of the open frame
  if i < 0 or i >= b.els.len:
    fail "take: nothing under that index"
  move b.els[i]

func pairsLen*(b: OpenFrame): int =
  ## how many whole pairs the draft holds
  ## Odd tails aren't pairs
  b.els.len div 2

func childrenLen*(b: OpenFrame): int =
  ## the children arity
  ## A record's head doesn't count as a child
  if b.kind == bRecord:
    max(0, b.els.len - 1)
  else:
    b.els.len

func takeKey*(b: var OpenFrame, n: int): Value =
  ## move entry n's key out
  b.take(2 * n)

func takeVal*(b: var OpenFrame, n: int): Value =
  ## move entry n's value out
  b.take(2 * n + 1)

func takeChild*(b: var OpenFrame, i: int): Value =
  ## move child i out
  ## A record's head doesn't count as a child
  if b.kind == bRecord:
    b.take(i + 1)
  else:
    b.take(i)

iterator mchildren*(b: var OpenFrame): var Value =
  ## yields children vars for in place access
  ## Like other "children" accessors a record's head isn't a child. 
  ## For dicts this walks every slot in a k v k v manner
  ## If you want value / key only manipulation use mpairs instead.
  ## 
  ## DO NOT ADD / MANIPULATE THE FRAME WHILE USING THIS! (probably)
  for i in (if b.kind == bRecord: 1 else: 0) ..< b.els.len:
    yield b.els[i]

iterator drainChildren*(b: var OpenFrame): Value =
  ## moves all children out of the frame
  ## Like the others, a record's head isn't a child!
  let start = if b.kind == bRecord: 1 else: 0
  for i in start ..< b.els.len:
    yield move b.els[i]

iterator drainPairs*(b: var OpenFrame): Entry =
  ## moves whole pairs out of the frame
  ## If there is an odd number of items in the frame
  ## it will leave behind the final value
  var i = 0
  while i + 1 < b.els.len:
    yield (move b.els[i], move b.els[i + 1])
    i += 2

iterator mpairs*(b: var OpenFrame): (lent Value, var Value) =
  ## allows for rewriting what the entries say
  ## A value only rewrite keeps canonical key order,
  ## so seal stays legitimate after using mpairs.
  ## For key rewrites use mchildren.
  ## This will skip the last odd trailling value if there
  ## is one
  var i = 0
  while i + 1 < b.els.len:
    yield (b.els[i], b.els[i + 1])
    i += 2

func canonicalize*(b: var OpenFrame) =
  ## Normalizes the contents of the open frame according to the CE
  ## ordering for it's kind without closing the open frame.
  ## 
  ## Sets will sort & dedup, dicts sort by key & refuse collisions.
  ## Positional kinds are untouched.
  ## An open frame created from a closed canonical value passes
  ## will pass in one verifying scan
  case b.kind
  of bSet:
    var sorted = true
    for i in 1 ..< b.els.len:
      if cmp(b.els[i - 1], b.els[i]) >= 0:
        sorted = false
        break
    if not sorted:
      b.els.sort(cmp)
      b.els.dedupSorted()
  of bDict:
    if b.els.len mod 2 != 0:
      fail "dict: a payload alternates key, value"
    var sorted = true
    var i = 2
    while i < b.els.len:
      if cmp(b.els[i - 2], b.els[i]) >= 0:
        sorted = false
        break
      i += 2
    if not sorted:
      canonicalizePairs(b.els)
  else:
    discard

func close*(b: sink OpenFrame): Value =
  ## close is one of two ways of converting an open frame to a 
  ## proper canonical frame value.
  ## 
  ## It is the more lenient of the two, and it will perform some
  ## soft normalization & corrections in the name of ergonomics.
  ## It will internally do canonicalization while refusing
  ## blatant misuse such as overlapping dict keys or records without
  ## a head.
  var bb = b
  canonicalize(bb)
  case bb.kind
  of bRecord:
    if bb.els.len == 0:
      fail "record: missing head"
    Value(kind: bRecord, marked: bb.marked, els: move bb.els)
  of bList:
    Value(kind: bList, marked: bb.marked, els: move bb.els)
  of bSet:
    Value(kind: bSet, marked: bb.marked, els: move bb.els)
  of bDict:
    Value(kind: bDict, marked: bb.marked, els: move bb.els)
  else:
    fail "close: not a frame kind"

func seal*(b: sink OpenFrame): Value =
  ## seal is the other way to convert an open frame to a proper
  ## canonical value.
  ## 
  ## Unlike close, it will not normalize and is useful when
  ## reading bytes from unknown sources and enforcing they
  ## are expressed correctly.
  ## You will most likely not use this during programatic
  ## construction of bassline values.
  case b.kind
  of bList:
    Value(kind: bList, marked: b.marked, els: move b.els)
  of bRecord:
    if b.els.len == 0:
      fail "record with no head"
    Value(kind: bRecord, marked: b.marked, els: move b.els)
  of bSet:
    for i in 1 ..< b.els.len:
      if cmp(b.els[i - 1], b.els[i]) >= 0:
        fail "set members out of order or duplicated"
    Value(kind: bSet, marked: b.marked, els: move b.els)
  of bDict:
    if b.els.len mod 2 != 0:
      fail "dict with a key missing its value"
    var i = 2
    while i < b.els.len:
      if cmp(b.els[i - 2], b.els[i]) >= 0:
        fail "dict keys out of order or duplicated"
      i += 2
    Value(kind: bDict, marked: b.marked, els: move b.els)
  else:
    fail "seal: not a frame kind"

# ================ CONSTRUCTORS ================

func toValue*(v: sink Value): Value = v

func nilValue*(marked = false): Value =
  Value(kind: bNil, marked: marked)

const Nil* = nilValue()

func num*[T](text: T, marked = false): Value =
  Value(kind: bNum, marked: marked, num: toDecimal(text))

func text*[T](text: T, marked = false): Value =
  Value(kind: bText, text: toValidUtf8(text), marked: marked)

func sym*[T](text: T, marked = false): Value =
  Value(kind: bSym, text: toValidUtf8(text), marked: marked)

func bytes*(bytes: sink seq[byte], marked = false): Value =
  Value(kind: bBytes, bytes: bytes, marked: marked)

func bytes*(s: string, marked = false): Value =
  Value(kind: bBytes, bytes: s.toBytes, marked: marked)

func list*(items: sink seq[Value], marked = false): Value =
  Value(kind: bList, marked: marked, els: items)

func list*(items: varargs[Value]): Value =
  list(@items, false)

func record*(items: sink seq[Value], marked = false): Value =
  close OpenFrame(kind: bRecord, marked: marked, els: items)

func record*(items: varargs[Value]): Value =
  record(@items, false)

func set*(items: sink seq[Value], marked = false): Value =
  close OpenFrame(kind: bSet, marked: marked, els: items)

func set*(items: varargs[Value]): Value =
  set(@items, false)

func dict*(entries: sink seq[Entry], marked = false): Value =
  var b = open(bDict, marked)
  for i in 0 ..< entries.len:
    b.add(move entries[i].key, move entries[i].val)
  close b

func dict*(entries: varargs[Entry]): Value =
  dict(@entries, false)