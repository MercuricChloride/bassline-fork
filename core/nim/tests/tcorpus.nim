import std/[os, sequtils, unittest]
import bassline

const Corpus = currentSourcePath().parentDir.parentDir.parentDir.parentDir / "corpus"

var reader = initReader()
let cases = reader.readAll(readFile(Corpus / "corpus.blb"))
doAssert not reader.starved

func payload(n: Node): string =
  n.asValue.vstr

proc ce(v: Value): string =
  v.write(result)

type Landed = object
  values: seq[Value]
  refused, starved: bool

proc land(bytes: string): Landed =
  var r = initReader()
  try:
    for v in r.readEach(bytes):
      result.values.add v
  except BasslineError:
    result.refused = true
  result.starved = r.starved

proc reads(text: string): bool =
  try:
    discard Value.parse(text)
    true
  except CatchableError:
    false

template landsOnly(landed: Landed, bytes: string) =
  let l = landed
  check not l.refused
  check l.values.mapIt(it.ce) == @[bytes]
  check not l.starved

template waits(landed: Landed) =
  let l = landed
  check not l.refused
  check l.values.len == 0
  check l.starved

suite "ce":
  for c in cases:
    matchValue c:
    of "(ce $name $value $bytes)":
      test name.payload:
        check value.asValue.ce == bytes.payload
        landsOnly bytes.payload.land, bytes.payload
    else: discard

suite "reject":
  for c in cases:
    matchValue c:
    of "(reject $name $bytes $_)":
      test name.payload:
        check bytes.payload.land.refused
    else: discard

suite "starved":
  for c in cases:
    matchValue c:
    of "(starved $name $bytes)":
      test name.payload:
        waits bytes.payload.land
    else: discard

suite "reads":
  for c in cases:
    matchValue c:
    of "(reads $text $value)":
      test text.payload:
        check text.payload.reads
        if text.payload.reads:
          check Value.parse(text.payload) == value.asValue
    else: discard

suite "refuses":
  for c in cases:
    matchValue c:
    of "(refuses $text)":
      test text.payload:
        check not text.payload.reads
    else: discard

suite "incomplete":
  for c in cases:
    matchValue c:
    of "(incomplete $text)":
      test text.payload:
        check not text.payload.reads
    else: discard

suite "document":
  for c in cases:
    matchValue c:
    of "(document $text $values)":
      test text.payload:
        check Value.parseMany(text.payload).mapIt(it.toNode) == values.asValue.vseq
    else: discard
