import std/[os, unittest]
import bl/core
import bl/lib/[json, blmacro]

const
  Corpus* = currentSourcePath().parentDir.parentDir.parentDir.parentDir / "corpus"

let
  cases* = readDocument(readFile(Corpus / "corpus.bl"))

template filter*(name, val, body) =
  bind cases
  for val in cases:
    if head(val) == bl(name):
      body

type Landed* = object
  values*: seq[ValueView]
  pending*: bool
  refused*: bool
  why*: string

template rejects*(s: string) =
  ## a ReadError of any kind including incomplete
  expect ReadError:
    discard readValue(s)

template incomplete*(s: string) =
  expect Incomplete:
    discard readValue(s)

template refuses*(s: string) =
  ## refused outright and not incomplete
  expect ReadError:
    try:
      discard readValue(s)
    except Incomplete:
      discard

proc land*(bytes: openArray[byte]): Landed =
  var d = newDecoder(newBuffer(bytes))
  try:
    for view in d.checked:
      result.values.add view
  except CodecError as e:
    result.refused = true
    result.why = e.msg
  result.pending = d.pending

when isMainModule:
  let
    records = newJArray()
    blb = newEncoder()

  for c in cases:
    doAssert c.kind == bRec, "a case is a record: " & $c
    records.add c.toJson
    blb.write c

  writeFile(Corpus / "corpus.json", records.pretty & "\n")
  writeFile(Corpus / "corpus.blb", blb.bytes.toString)
  echo cases.len, " cases -> corpus.json, corpus.blb"