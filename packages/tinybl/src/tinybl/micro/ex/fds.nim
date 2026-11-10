import std/[posix, oserrors, hashes]
import ./ce

refuseWith BasslineError

const
  TagShift = 49
  AddrMask = (1'u64 shl TagShift) - 1
  MaxTagged = (1 shl (64 - TagShift)) - 1

type
  ValuePtr* = distinct uint64

  PointerReader* = object
    file: File
    base: ptr UncheckedArray[byte]
    size: int

  Step = tuple[adv, depth: int8]

proc `=destroy`*(r: PointerReader) =
  if r.base != nil:
    discard munmap(r.base, r.size)
  if r.file != nil:
    r.file.close

proc `=copy`*(a: var PointerReader, b: PointerReader) {.error.}

const Steps = block:
  var steps: array[256, Step]
  for b in 0 .. 255:
    try:
      steps[b] =
        case partialKind(byte b)
        of pvNil: (1'i8, 0'i8)
        of pvOpenFrame: (1'i8, 1'i8)
        of pvCloseFrame: (1'i8, -1'i8)
        of pvAtom:
          let l = headerData(byte b).inlineLen
          if l < 7: (int8(1 + l), 0'i8) else: (0'i8, 0'i8)
    except BasslineError:
      discard
  steps

template address(v: ValuePtr): uint64 =
  uint64(v) and AddrMask

template bytes(v: ValuePtr): ptr UncheckedArray[byte] =
  cast[ptr UncheckedArray[byte]](v.address)

template chars(v: ValuePtr): ptr UncheckedArray[char] =
  cast[ptr UncheckedArray[char]](v.address)

template at(p: ptr UncheckedArray[byte], i: int): ValuePtr =
  ValuePtr(cast[uint64](addr p[i]))

template rest(p: ptr UncheckedArray[byte], i: int): ptr UncheckedArray[byte] =
  cast[ptr UncheckedArray[byte]](addr p[i])

func tagged(p: ptr UncheckedArray[byte], i, extent: int): ValuePtr {.inline.} =
  let tag = if extent <= MaxTagged: uint64(extent) shl TagShift else: 0'u64
  ValuePtr(cast[uint64](addr p[i]) or tag)

func known(v: ValuePtr): int {.inline.} =
  int(uint64(v) shr TagShift)

func be32(p: ptr UncheckedArray[byte], i: int): int {.inline.} =
  (p[i].int shl 24) or (p[i + 1].int shl 16) or (p[i + 2].int shl 8) or p[i + 3].int

func atomHead(p: ptr UncheckedArray[byte], i: int): tuple[head, len: int] {.inline.} =
  let l = int(p[i] and 7)
  if l < 7: (1, l)
  elif p[i + 1] != 255: (2, p[i + 1].int)
  else: (6, p.be32(i + 2))

const OpenTag = bList.tag

func isOpen(b: byte): bool {.inline.} =
  b != EndByte and (b shr 4) >= OpenTag

proc openPointerReader*(path: string): PointerReader =
  result.file = open(path)
  result.size = result.file.getFileSize.int
  if result.size > 0:
    let p = mmap(nil, result.size, PROT_READ, MAP_PRIVATE, result.file.getFileHandle, 0)
    if p == MAP_FAILED:
      raiseOSError(osLastError(), path)
    result.base = cast[ptr UncheckedArray[byte]](p)
    guard cast[uint64](p) + uint64(result.size) <= AddrMask,
      "mapped above the addresses a ValuePtr holds"

proc judge(r: PointerReader, start: int): int =
  template cutShort(n: int) =
    guard pos + n <= r.size, "value cut short by the end of the input"
  var
    pos = start
    depth = 0
  while true:
    cutShort 1
    let
      b = r.base[pos]
      s = Steps[b]
    if s.adv != 0:
      pos += s.adv
      depth += s.depth
    else:
      discard partialKind(b)
      cutShort 2
      var
        head = 2
        len = r.base[pos + 1].int
      guard len >= 7, "non minimal medium length"
      if len == 255:
        cutShort 6
        head = 6
        len = r.base.be32(pos + 2)
        guard len >= 255, "non minimal large length"
      pos += head + len
    if uint(depth) > uint(MaxDepth):
      guard depth > 0, "end at top level"
      refuse "frames nested deeper than MaxDepth"
    if pos - start > MaxValueBytes and s.depth <= 0:
      refuse "value larger than MaxValueBytes"
    if depth == 0:
      guard pos <= r.size, "value cut short by the end of the input"
      return pos

proc next*(r: PointerReader, pos: var int, v: var ValuePtr): bool =
  guard pos >= 0, "position before the start of the input"
  if pos >= r.size:
    return false
  let start = pos
  pos = r.judge(start)
  v = r.base.tagged(start, pos - start)
  true

iterator items*(r: PointerReader): ValuePtr =
  var
    pos = 0
    v: ValuePtr
  while r.next(pos, v):
    yield v

func kind*(v: ValuePtr): Kind {.inline.} =
  Kind((v.bytes[0] shr 4) - 1)

func mark*(v: ValuePtr): bool {.inline.} =
  (v.bytes[0] and MarkBit) != 0

func extentOf(p: ptr UncheckedArray[byte]): int =
  var depth = 0
  while true:
    let b = p[result]
    if b == EndByte:
      dec depth
      inc result
    elif b.isOpen:
      inc depth
      inc result
    else:
      let (head, len) = p.atomHead(result)
      result += head + len
    if depth == 0:
      return

func stride*(v: ValuePtr): int =
  result = v.known
  if result == 0:
    result = v.bytes.extentOf

func span(v: ValuePtr): Slice[int] {.inline.} =
  let (head, len) = v.bytes.atomHead(0)
  head ..< head + len

template payload*(v: ValuePtr): openArray[char] =
  toOpenArray(v.chars, v.span.a, v.span.b)

template ce*(v: ValuePtr): openArray[char] =
  toOpenArray(v.chars, 0, v.stride - 1)

func text*(v: ValuePtr): string =
  let s = v.span
  if s.len > 0:
    copyMem(beginStore(result, s.len), addr v.chars[s.a], s.len)
    endStore(result)

iterator members*(v: ValuePtr): ValuePtr =
  let p = v.bytes
  if p[0].isOpen:
    var i = 1
    while p[i] != EndByte:
      let n = p.rest(i).extentOf
      yield p.tagged(i, n)
      i += n

func len*(v: ValuePtr): int =
  for _ in v.members:
    inc result

iterator walk*(v: ValuePtr): ValuePtr =
  let p = v.bytes
  var
    i = 0
    depth = 0
  while true:
    let b = p[i]
    if b == EndByte:
      dec depth
      inc i
    else:
      yield p.at(i)
      if b.isOpen:
        inc depth
        inc i
      else:
        let (head, len) = p.atomHead(i)
        i += head + len
    if depth == 0:
      break

func lockstep(a, b: ptr UncheckedArray[byte]): int =
  var
    i = 0
    depth = 0
  while true:
    if a[i] != b[i]:
      return cmp(a[i], b[i])
    let s = Steps[a[i]]
    var head, len: int
    if s.adv != 0:
      head = 1
      len = s.adv - 1
      depth += s.depth
    else:
      if a[i + 1] != b[i + 1]:
        return cmp(a[i + 1], b[i + 1])
      (head, len) = a.atomHead(i)
      if head == 6:
        result = cmpMem(addr a[i + 2], addr b[i + 2], 4)
        if result != 0:
          return
    if len > 0:
      result = cmpMem(addr a[i + head], addr b[i + head], len)
      if result != 0:
        return
    i += head + len
    if depth == 0:
      return 0

func cmp*(a, b: ValuePtr): int =
  let
    la = a.known
    lb = b.known
  if la != 0 and lb != 0:
    result = cmpMem(a.bytes, b.bytes, min(la, lb))
    if result == 0:
      result = cmp(la, lb)
  else:
    result = lockstep(a.bytes, b.bytes)

func `==`*(a, b: ValuePtr): bool =
  let
    la = a.known
    lb = b.known
  if la != 0 and lb != 0 and la != lb:
    return false
  a.address == b.address or cmp(a, b) == 0

func hash*(v: ValuePtr): Hash =
  hash(v.ce)

proc build*[V; B: BuildAlg[V]](v: ValuePtr, builder: B): V =
  var
    r = initReader[V, B](builder)
    pos = 0
  discard r.readCE(v.ce, pos)
  move r.value

when isMainModule:
  import std/[monotimes, times, os, strutils]
  import ./values

  let
    path = if paramCount() > 0: paramStr(1) else: "/Users/goose/prg/jordans-bl/jams/jam.blb"
    size = getFileSize(path).float / 1_000_000

  template time(label: string, body: untyped) =
    var best = float.high
    for _ in 0 ..< 5:
      let t0 = getMonoTime()
      body
      best = min(best, (getMonoTime() - t0).inNanoseconds.float / 1e6)
    echo "  ", label.alignLeft(36), best.formatFloat(ffDecimal, 1).align(9), " ms"

  echo path.extractFilename, ", ", size.formatFloat(ffDecimal, 1), " MB"
  var sink: int
  time "pointers":
    for v in openPointerReader(path):
      sink += v.bytes[0].int
  time "pointers, every node walked":
    for v in openPointerReader(path):
      for n in v.walk:
        sink += n.bytes[0].int
  time "pointers, every value hashed":
    for v in openPointerReader(path):
      sink = sink xor v.hash
  time "pointers, each compared with the next":
    var last: ValuePtr
    for v in openPointerReader(path):
      if uint64(last) != 0:
        sink += cmp(last, v)
      last = v
  time "pointers, each built into RawValue":
    for v in openPointerReader(path):
      sink += v.build(BuildRaw).len
  let whole = readFile(path)
  time "RawValue from bytes in memory":
    var reader = initReader(BuildRaw)
    for v in reader.readEach(whole):
      sink += v.len
  echo "  (", sink mod 7, ")"