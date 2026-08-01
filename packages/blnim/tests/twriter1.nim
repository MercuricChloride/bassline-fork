## The streaming writer must produce exactly what `encode` produces, at
## every size relative to its 256 KiB staging buffer.
import std/[unittest, os, sequtils, random]
from std/strutils import join
import pkg/core
import pkg/cmd/util

const Buf = 256 * 1024

proc streamed(vs: seq[Value]): seq[byte] =
  let tmp = getTempDir() / "bl-twriter-out"
  let f = open(tmp, fmWrite)
  var w = writerOn(f)
  for v in vs:
    w.writeValue v
  w.flush()
  f.close()
  result = readFile(tmp).toBytes
  removeFile tmp

proc batched(vs: seq[Value]): seq[byte] =
  for v in vs:
    result.add encode(v)

proc check1(v: Value): bool =
  streamed(@[v]) == encode(v)

suite "streaming writer == encode":
  test "sizes around the staging buffer":
    for n in [
      0, 1, 6, 7, 8, 254, 255, 256, 65535, 65536,
      Buf - 1, Buf, Buf + 1, 2 * Buf - 1, 2 * Buf, 2 * Buf + 1,
    ]:
      check check1 bytes(newSeqWith(n, byte 0xEE))
      check check1 text(newSeqWith(n, 'a').join)

  test "a frame whose children straddle the boundary":
    for n in [Buf - 2, Buf - 1, Buf, Buf + 1]:
      check check1 list(
        bytes(newSeqWith(n, byte 1)), bytes(@[byte 2]), bytes(newSeqWith(n, byte 3))
      )

  test "many small values in one writer, in one file":
    var vs: seq[Value]
    var r = initRand(7)
    for i in 0 ..< 4000:
      vs.add bytes(newSeqWith(r.rand(1 .. 200), byte(i and 0xFF)))
    check streamed(vs) == batched(vs)

  test "nested frames and every kind":
    let v = record(@[
      sym"h",
      list(num"1", text"two", bytes(newSeqWith(Buf + 9, byte 7))),
      set(num"3", num"1"),
      dict([(sym"a", num"1"), (sym"b", bytes(newSeqWith(Buf, byte 2)))]),
      list(sym"q").mark,
      nilValue(),
    ])
    check check1 v
    check decode(streamed(@[v])) == v

  test "empty and marked frames":
    for v in [list(), set(newSeq[Value]()), mark(list()), nilValue(true)]:
      check check1 v
