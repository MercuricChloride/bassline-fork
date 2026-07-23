import std/unittest
import std/options
import std/sequtils
from std/strutils import repeat
import pkg/core

# a corpus exercising every kind, the mark bit, and all length tiers
let corpus = @[
  nilValue(),
  nilValue(true),
  num"0",
  num"-123456789012345",
  sym"x",
  mark(sym"f"),
  text"",
  text"hello",
  text(repeat('a', 6)),
  text(repeat('b', 7)),
  text(repeat('c', 254)),
  text(repeat('d', 255)),
  text(repeat('e', 70_000)),
  bytes(newSeqWith(300, byte 0xEE)),
  list(),
  record(sym"h", num"1"),
  set(num"3", num"1", num"2"),
  dict(@[(sym"a", num"1"), (sym"b", list(text"x", nilValue()))]),
  mark(list(sym"q", record(sym"add", num"1", num"2"))),
  list(list(list(num"9"))),
]

func concatEncoded(values: seq[Value]): seq[byte] =
  for v in values:
    result.add encode(v)

proc drain(sd: var StreamDecoder): seq[Value] =
  while true:
    let v = sd.next()
    if v.isNone:
      break
    result.add v.get

proc streamed(bytes: seq[byte], chunk: int): seq[Value] =
  var sd = initStreamDecoder()
  var i = 0
  while i < bytes.len:
    let stop = min(i + chunk, bytes.len)
    sd.feed(bytes.toOpenArray(i, stop - 1))
    result.add sd.drain()
    i = stop
  doAssert sd.buffered == 0, "leftover bytes after a complete stream"

proc streamRejects(bs: seq[byte]): bool =
  # drip one byte at a time to stress every resumption path
  var sd = initStreamDecoder()
  try:
    for b in bs:
      sd.feed([b])
      discard sd.drain()
    false
  except DecodeError:
    true

suite "stream equals batch under any chunking":
  test "chunk size sweep":
    let bytes = concatEncoded(corpus)
    for chunk in [1, 2, 3, 5, 7, 16, 64, 1024, bytes.len]:
      check streamed(bytes, chunk) == corpus

  test "many values in one feed plus a trailing partial":
    var sd = initStreamDecoder()
    let bytes = concatEncoded(corpus)
    let tail = encode(text"straggler")
    sd.feed(bytes)
    sd.feed(tail.toOpenArray(0, tail.len - 2))
    check sd.drain() == corpus
    check sd.buffered == tail.len - 1
    sd.feed([tail[^1]])
    check sd.drain() == @[text"straggler"]
    check sd.buffered == 0

  test "splits inside the large length tier":
    # 70k text: header byte, 0xFF, then 4 big-endian length bytes
    let bytes = encode(text(repeat('e', 70_000)))
    for cut in 1 .. 6:
      var sd = initStreamDecoder()
      sd.feed(bytes.toOpenArray(0, cut - 1))
      check sd.next().isNone
      sd.feed(bytes.toOpenArray(cut, bytes.len - 1))
      check sd.next().get == text(repeat('e', 70_000))

suite "stream rejections":
  test "malformation is fatal wherever it sits":
    check streamRejects @[byte 0x00] # invalid tag 0x0
    check streamRejects @[byte 0xB0] # invalid tag 0xB
    check streamRejects @[byte 0xA0] # END at top level
    check streamRejects @[byte 0x60, 0xA8] # END with flag bits
    check streamRejects @[byte 0x13] # nil with length bits
    check streamRejects @[byte 0x70, 0xA0] # record with no head
    check streamRejects @[byte 0x80, 0x21, 0x31, 0xA0] # dict key sans value
    check streamRejects @[byte 0x90, 0x21, 0x32, 0x21, 0x31, 0xA0] # set order
    check streamRejects @[byte 0x37, 0x03, 0x61, 0x62, 0x63] # non-canonical len
    check streamRejects @[byte 0x31, 0xFF] # malformed utf-8
    check streamRejects @[byte 0x21, 0x61] # non-decimal num

  test "a good value lands before the bad byte kills the stream":
    var sd = initStreamDecoder()
    sd.feed(encode(num"1"))
    sd.feed([byte 0x00])
    check sd.next().get == num"1"
    expect DecodeError:
      discard sd.next()

  test "depth limit at scan time":
    check streamRejects newSeqWith(65, byte 0x60)

  test "frame headers with length bits fail at scan time":
    check streamRejects @[byte 0x67]

  test "the size limit binds regardless of chunking":
    # header-only bytes declare no sizes, so this list of nils only
    # reveals its total when it completes -- even inside one feed
    var bs = @[byte 0x60]
    for i in 0 ..< 30:
      bs.add 0x10
    bs.add 0xA0
    var sd = initStreamDecoder(maxValueBytes = 16)
    sd.feed(bs)
    expect DecodeError:
      discard sd.next()

  test "declared size over the limit rejects before payload arrives":
    var sd = initStreamDecoder(maxValueBytes = 16)
    expect DecodeError:
      # text declaring 100 bytes: header + medium length byte only
      sd.feed([byte 0x37, 100])
      discard sd.next()

  test "an endless open frame is cut off at the limit":
    var sd = initStreamDecoder(maxValueBytes = 16)
    expect DecodeError:
      for i in 0 ..< 20:
        sd.feed([byte 0x60]) # ever-deeper unclosed lists... of lists
        discard sd.next()

  test "a value exactly at the limit is accepted":
    let v = text(repeat('a', 14)) # header + medium byte + 14 = 16
    check encode(v).len == 16
    var sd = initStreamDecoder(maxValueBytes = 16)
    sd.feed(encode(v))
    check sd.next().get == v
