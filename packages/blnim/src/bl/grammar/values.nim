## Values as a source. A frame's members are read the way text is, so a
## value is taken apart by a grammar, with ordered choice, repetition and
## a message that says where it did not fit, as a path. Also the pass over
## what the text and CE grammars build: `canonical` for CE and `sorted`
## for text, each finishing a structural value where it stands or refusing
## it with the path of the member that would not do.

import std/[strutils, sugar]
import petit_parser
import ../core
import ./bassline_text

refuseWith BasslineError

type ValueParser*[R] = Parser[Members, R]

proc makeValues*(): Make[Value] =
  ## Builds values. A set or dict comes out with its members in the order
  ## given, held in a sequence frame, until `canonical` or `sorted` makes
  ## the real thing of it.
  Make[Value](
    atom: proc (k: Kind, payload: sink string, mark: bool): Value =
      case k
      of bNil: Value(kind: bNil, mark: mark)
      of bNum: Value(kind: bNum, mark: mark, num: initNum(payload))
      of bText: Value(kind: bText, mark: mark, text: payload)
      else: Value(kind: bSym, mark: mark, text: payload),
    bytes: proc (b: sink seq[byte], mark: bool): Value =
      Value(kind: bBytes, mark: mark, bytes: b),
    frame: proc (k: Kind, members: sink seq[Value], mark: bool): Value =
      let buf = newBuffer(members)
      case k
      of bList: Value(kind: bList, mark: mark, frame: buf)
      of bRec: Value(kind: bRec, mark: mark, frame: buf)
      of bSet: Value(kind: bSet, mark: mark, frame: buf)
      of bDict: Value(kind: bDict, mark: mark, frame: buf)
      else: refuse("not a frame kind: " & $k),
    mark: proc (v: sink Value): Value =
      result = v
      result.mark = true)

# ---------------------------------------------------------------------------
# Where a member is

proc locatePath(input: InputBase, pos: int): string =
  ## a member's place from the value parsed, as `2.0.3`; the value itself
  ## has no path
  let p = input.place(pos)
  if p.len == 1: "the value" else: p[1 .. ^1].join(".")

proc newInput*(m: Members): Input[Members] =
  result = parser.newInput[Members](m)
  result.locateFn = locatePath

proc parse*[R](p: ValueParser[R], v: Value): Result[R] =
  ## `p` over one value, which it must take whole.
  p.complete.parse(Members(Frame(newBuffer(@[v]))))

# ---------------------------------------------------------------------------
# Leaves

proc valueWhere*(pred: (Value) -> bool, expected: string): ValueParser[Value] =
  item[Members](pred, expected)

proc anyValue*(): ValueParser[Value] = valueWhere((v: Value) => true, "a value")

proc ofKind*(k: Kind, mark = anyMark): ValueParser[Value] =
  valueWhere((v: Value) => v.isKind(k, mark), $k)

proc nilValue*(mark = anyMark): ValueParser[Value] = ofKind(bNil, mark)
proc number*(mark = anyMark): ValueParser[BNum] = ofKind(bNum, mark).map((v: Value) => v.num)
proc textOf*(mark = anyMark): ValueParser[string] = ofKind(bText, mark).map((v: Value) => v.text)
proc symbolOf*(mark = anyMark): ValueParser[string] = ofKind(bSym, mark).map((v: Value) => v.text)
proc bytesOf*(mark = anyMark): ValueParser[seq[byte]] = ofKind(bBytes, mark).map((v: Value) => v.bytes)

proc symbol*(name: string, mark = unmarked): ValueParser[Value] =
  ## The one symbol `name`, unmarked unless said otherwise.
  valueWhere((v: Value) => v.isKind(bSym, mark) and v.text == name, name)

# ---------------------------------------------------------------------------
# Frames: a member whose own members are read whole by another parser

proc frameOf*[R](kind: Kind, inner: ValueParser[R], mark = anyMark): ValueParser[(bool, R)] =
  ## A frame of `kind`, its members read whole by `inner`. Answers the
  ## frame's mark and what `inner` made of the members, so a reading can
  ## build the frame again.
  let
    whole = inner.complete
    want = failure[Members, Nothing]($kind)
  whole.callCC(proc (next: ValueParser[R], ctx: Context[Members]): Result[(bool, R)] =
    if ctx.pos >= ctx.input.stop: return fail[Members, (bool, R)](want, ctx)
    let v = ctx.input.source[ctx.pos]
    if not v.isKind(kind, mark): return fail[Members, (bool, R)](want, ctx)
    var r = next.parseOn(Context[Members](input: child(ctx.input, ctx.pos, v.members), pos: 0))
    if not r.isSuccess: return failedAs((bool, R), r)
    succeed((v.mark, r.take), ctx.pos + 1))

proc listOf*[R](inner: ValueParser[R], mark = anyMark): ValueParser[R] =
  frameOf(bList, inner, mark).pick(1)
proc recordOf*[R](inner: ValueParser[R], mark = anyMark): ValueParser[R] =
  frameOf(bRec, inner, mark).pick(1)
proc setOf*[R](inner: ValueParser[R], mark = anyMark): ValueParser[R] =
  frameOf(bSet, inner, mark).pick(1)
proc dictOf*[R](inner: ValueParser[R], mark = anyMark): ValueParser[R] =
  ## A dict's members come as its keys and values alternating.
  frameOf(bDict, inner, mark).pick(1)

proc entries*[K, V](key: ValueParser[K], val: ValueParser[V]): ValueParser[seq[(K, V)]] =
  ## Keys and values in turn, as a dict's members are read.
  (key & val).star

# ---------------------------------------------------------------------------
# The pass: from what a grammar built to a finished value. Not a grammar:
# a walk that finishes each frame where it stands, in the body the grammar
# built, moving members into a set's or dict's tree once they are checked.

type Order = enum
  inOrder    ## members must stand in canonical order already: CE
  anyOrder   ## members stand in any order and are sorted here: text

proc located(path: openArray[int]): string =
  if path.len == 0: "the value" else: path.join(".")

proc located(path: seq[int], i: int): string = located(path & i)

proc utf8(v: Value): bool = isValidUtf8(v.text.toOpenArrayByte(0, v.text.high))

proc finish(v: var Value, path: var seq[int], order: Order) =
  template within(i: int, body: untyped) =
    path.add i
    body
    path.setLen path.len - 1
  case v.kind
  of bNil, bNum, bBytes: discard
  of bText: guard v.utf8, "malformed UTF-8 in text at " & path.located
  of bSym: guard v.utf8, "malformed UTF-8 in a symbol at " & path.located
  of bList, bRec:
    for i, m in BSeq(v.frame).data.mpairs:
      within i: finish(m, path, order)
  of bSet:
    if not (v.frame of BSeq): return   # a set already
    let items = BSeq(v.frame)
    for i, m in items.data.mpairs:
      within i: finish(m, path, order)
    case order
    of inOrder:
      for i in 1 ..< items.len:
        let c = cmp(items.data[i - 1], items.data[i])
        guard c != 0, "repeated member at " & path.located(i)
        guard c < 0, "members out of canonical order at " & path.located(i)
      v.frame = fromSortedSet(move items.data)
    of anyOrder:
      let s = newBSet()
      for i, m in items.data.mpairs:
        let before = s.len
        s.incl move m
        guard s.len > before, "repeated member at " & path.located(i)
      v.frame = s
  of bDict:
    if not (v.frame of BSeq): return   # a dict already
    let
      items = BSeq(v.frame)   # keys and values alternating
      n = items.len div 2
    for i, m in items.data.mpairs:
      within i: finish(m, path, order)
    case order
    of inOrder:
      for i in 1 ..< n:
        let c = cmp(items.data[2 * i - 2], items.data[2 * i])
        guard c != 0, "repeated key at " & path.located(2 * i)
        guard c < 0, "keys out of canonical order at " & path.located(2 * i)
      var es = newSeqOfCap[Entry[Value, Value]](n)
      for i in 0 ..< n:
        es.add (key: move items.data[2 * i], val: move items.data[2 * i + 1])
      v.frame = fromSorted(es)
    of anyOrder:
      let d = newBDict()
      for i in 0 ..< n:
        let before = d.len
        d[move items.data[2 * i]] = move items.data[2 * i + 1]
        guard d.len > before, "repeated key at " & path.located(2 * i)
      v.frame = d

proc canonical*(v: var Value) =
  ## Finishes a value the CE grammar built, where it stands: text and
  ## symbols valid UTF-8, a set's members and a dict's keys strictly
  ## ascending in CE order with nothing repeated. Sets and dicts get their
  ## trees, built straight from the order given. Refuses with the path of
  ## the member that would not do, and leaves the value part finished.
  var path: seq[int]
  finish(v, path, inOrder)

proc sorted*(v: var Value) =
  ## Finishes a value the text grammar built, where it stands: members in
  ## any order, sorted here, nothing repeated, valid UTF-8.
  var path: seq[int]
  finish(v, path, anyOrder)
