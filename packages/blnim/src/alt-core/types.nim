include pkg/prelude
import std/hashes
import ./macros
export hashes, macros

type
  RefuseError* = object of CatchableError
  BlKind* = enum
    bNil,
    bNum, bText, bSym, bBytes,
    bList, bRecord, bDict, bSet

  Value* = concept
    func marked(s: Self): bool
    func kind(s: Self): BlKind
    func size(s: Self): int
    func payload(s: Self): lent seq[byte]
    func els(s: Self): lent seq[Self]
    proc null(_: typedesc[Self], marked: bool): Self
    proc atom(_: typedesc[Self], payload: openArray[byte], kind: Atoms, marked: bool): Self
    proc frame(_: typedesc[Self], els: sink seq[Self], kind: Frames, marked: bool): Self

  Atoms* = range[bNum..bBytes]
  Frames* = range[bList..bSet]

const
  AtomKinds* = bNil..bBytes
  SizedKinds* = bNum..bBytes
  FrameKinds* = bList..bSet

template refuse*(msg: untyped) =
  raise newException(RefuseError, msg)

func tag*(a: Value): int =
  ord(a.kind) + 1

func len*(a: Value): int =
  a.payload.len

# ================ ORDERING ================
# We have to use constrained generics here, because by default
# same value comparisons wont work with case objects, since
# we need to outrank systems cmp[T: tuple|object]
# this also has the cruft of making us require a
# cmp(a, b: MyValue): int with the concrete types directly

func cmp*[A, B: Value](a: A, b: B): int
func `==`*[A, B: Value](a: A, b: B): bool =
  cmp(a, b) == 0
func `>`*[A, B: Value](a: A, b: B): bool =
  cmp(a, b) > 0
func `>=`*[A, B: Value](a: A, b: B): bool =
  cmp(a, b) >= 0
func `<`*[A, B: Value](a: A, b: B): bool =
  cmp(a, b) < 0
func `<=`*[A, B: Value](a: A, b: B): bool =
  cmp(a, b) <= 0

func cmpAtoms(a, b: openArray[byte]): int =
  result = cmp(a.len, b.len)
  if result != 0: return
  for i in 0 ..< a.len:
    result = cmp(a[i], b[i])
    if result != 0: return

func cmpFrames[A, B: Value](a: openArray[A], b: openArray[B]): int =
  for i in 0 ..< min(a.len, b.len):
    result = cmp(a[i], b[i])
    if result != 0: return
  # Note! This looks backwards, but when comparing frames
  # the end byte (0xA0) is > all other header bytes
  # so a > b if a is a prefix of b
  result = cmp(b.len, a.len)

func cmp*[A, B: Value](a: A, b: B): int =
  result = cmp(a.tag, b.tag)
  if result != 0: return

  result = cmp(a.marked, b.marked)
  if result != 0: return

  if a.kind == bNil: discard
  elif a.kind in AtomKinds:
    result = cmpAtoms(a.payload, b.payload)
  else:
    result = cmpFrames(a.els, b.els)

func hashValue*[A: Value](v: A): Hash =
  ## This is not a cryptographic hash!
  ## This is used for things like tables & hash sets.
  ## Use lib/digest for cryptographic hashing.
  ## implementations get a concrete `hash` from defvalue that
  ## forwards here
  var h: Hash = 0
  h = h !& hash(v.tag) !& hash(v.marked) !& hash(v.size)
  if v.kind == bNil: discard
  elif v.kind in AtomKinds:
    h = h !& hash(v.payload)
  else:
    h = h !& hash(v.els)
  result = !$h

# iteration
iterator slide*[T](els: openArray[T], n: int): openArray[T] =
  var i = 0
  while (i + n) <= els.len:
    yield els[i..<(i + n)]
    i += n

iterator entries*(v: Value): (Value, Value) =
  if v.kind != bDict:
    refuse "entries: not a dict"
  for pair in v.els.slide(2):
    yield (pair[0], pair[1])

# ================ Aliases for verbose generics ================

proc atom*[T: Value](
  s: openArray[byte], kind: Atoms = bText, marked = false): T =
  mixin atom
  T.atom(s, kind, marked)

proc frame*[T: Value](
  els: sink seq[T], kind: Frames = bList, marked = false): T =
  mixin frame
  T.frame(els, kind, marked)

proc null*[T: Value](
  marked = false
): T =
  mixin null
  T.null(marked)

proc atom*[T: Value](
  s: string, kind: Atoms = bText, marked = false): T =
  mixin atom
  T.atom(s.toOpenArrayByte(0, s.high), kind, marked)