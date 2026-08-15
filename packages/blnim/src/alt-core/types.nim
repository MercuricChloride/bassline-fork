include pkg/prelude
import std/hashes

type
  RefuseError* = object of CatchableError
  BlKind* = enum
    bNil,
    bNum, bText, bSym, bBytes,
    bList, bRecord, bDict, bSet

  Header* = concept v
    v.marked is bool
    v.kind is BlKind
    v.size is int

  Atom* = concept v
    v is Header
    v.payload is lent seq[byte]

  Frame* = concept v
    v is Header
    v.els is lent seq[Value]

  Value* = Atom | Frame

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

func cmp*(a, b: Value): int

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

func cmpAtoms(a, b: openArray[byte]): int =
  result = cmp(a.len, b.len)
  if result != 0: return
  for i in 0 ..< a.len:
    result = cmp(a[i], b[i])
    if result != 0: return

func cmpFrames[T: Value](a, b: openArray[T]): int =
  for i in 0 ..< min(a.len, b.len):
    result = cmp(a[i], b[i])
    if result != 0: return
  # Note! This looks backwards, but when comparing frames
  # the end byte (0xA0) is > all other header bytes
  # so a > b if a is a prefix of b
  result = cmp(b.len, a.len)

func cmp*(a, b: Value): int =
  result = cmp(a.tag, b.tag)
  if result != 0: return

  result = cmp(a.marked, b.marked)
  if result != 0: return

  if a.kind == bNil: discard
  elif a.kind in AtomKinds:
    result = cmpAtoms(a.payload, b.payload)
  else:
    result = cmpFrames(a.els, b.els)

func hash*(v: Value): Hash =
  ## This is not a cryptographic hash!
  ## This is used for things like tables & hash sets.
  ## Use lib/digest for cryptographic hashing
  var h: Hash = 0
  h = h !& hash(v.tag) !& hash(v.marked) !& hash(v.size)
  if v.kind == bNil: discard
  elif v.kind in AtomKinds:
    h = h !& hash(v.payload)
  else:
    h = h !& hash(v.els)
  result = !$h

iterator slide*[T](els: openArray[T], n: int): openArray[T] =
  var i = 0
  while (i + n) <= high(els):
    yield els[i..<(i + n)]
    i += n

iterator entries*(v: Value): (Value, Value) =
  if v.kind != bDict:
    refuse "entries: not a dict"
  for pair in v.els.slide(2):
    yield (pair[0], pair[1])