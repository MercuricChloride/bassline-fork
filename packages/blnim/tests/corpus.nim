import std/os
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