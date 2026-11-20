import std/[monotimes, os, strutils, times]
import bassline

const Rooms = ["general", "forge", "fs", "review"]

proc jamLike(count: int): string =
  for i in 0 ..< count:
    let
      room = Sym(Rooms[i mod Rooms.len])
      rank = Num(i)
      by = Sym("agent-" & $(i mod 17))
      said = Text("message " & $i & " " & "lorem ipsum ".repeat(i mod 9))
      at = Num(1_763_600_000_000 + i * 997)
    bl"($room $rank !{(by $by) (said $said) (at $at)})".write(result)

proc readAll(bytes: string): seq[Value] =
  var r = initReader()
  for v in r.readEach(bytes):
    result.add v
  doAssert not r.starved, "input ended inside a value"

template best(label: string, body: untyped) =
  var ms = float.high
  for _ in 0 ..< 7:
    let start = getMonoTime()
    body
    ms = min(ms, (getMonoTime() - start).inNanoseconds.float / 1e6)
  echo label.alignLeft(8), formatFloat(ms, ffDecimal, 1).align(8), " ms"

proc main =
  when not defined(release):
    echo "built without -d:release, so the timings mean little"
  let
    input = if paramCount() > 0: readFile(paramStr(1)) else: jamLike(50_000)
    values = input.readAll

  var written: string
  for v in values:
    v.write written
  doAssert written == input, "writing what was read changed the bytes"

  var
    r = initReader()
    trickled: string
  for i in 0 ..< input.len:
    for v in r.readEach(input.toOpenArray(i, i)):
      v.write trickled
  doAssert trickled == input and not r.starved, "reading a byte at a time changed the bytes"

  for i in 0 ..< min(values.len, 2_000):
    doAssert Value.parse($values[i]) == values[i], "printing and reading back changed a value"

  echo formatFloat(input.len / 1_000_000, ffDecimal, 1), " MB, ", values.len, " values"
  best "decode":
    var r = initReader()
    var pos = 0
    while r.readCE(input, pos): discard
  var o: string
  best "encode":
    o.setLen 0
    for v in values:
      v.write o
  best "print":
    for i in 0 ..< min(values.len, 20_000):
      o = $values[i]

main()
