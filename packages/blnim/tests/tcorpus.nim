## the shared corpus, run against this implementation: one suite per
## case head, one test per case. corpus.nim run as a program derives
## corpus.json and corpus.blb from the same document; the last suite
## checks that what is on disk still reads back as the cases.

import std/[os, strutils, unittest]
import bl/core
import bl/lib/[json, blmacro]
import ./corpus

proc ceBytes(self: Value): seq[byte] =
  let enc = newEncoder()
  enc.write self
  enc.buf.data

type Landed = object
  values: seq[ValueView]
  pending: bool
  error: string

proc land(bytes: seq[byte]): Landed =
  ## everything the decoder yields for bytes, and how it was left
  var d = newDecoder(newBuffer(bytes))
  try:
    for view in d.checked:
      result.values.add view
  except CodecError as e:
    result.error = e.msg
  result.pending = d.pending

type Outcome = enum read, refused, incomplete

proc reading(src: string, whole = false): Outcome =
  ## how the reader leaves src: whole reads it as a document
  try:
    if whole: discard readDocument(src)
    else: discard readValue(src)
    read
  except Incomplete:
    incomplete
  except ReadError:
    refused

suite "ce":
  filter ce, c:
    let
      name = c.items[1].text
      value = c.items[2]
      expect = c.items[3].bytes
    test name:
      check ceBytes(value) == expect
      let l = land(expect)
      check l.error == ""
      check l.values.len == 1
      check not l.pending
      if l.values.len == 1:
        check l.values[0].toValue == value
      check readValue($value) == value

suite "reject":
  filter reject, c:
    let
      name = c.items[1].text
      bytes = c.items[2].bytes
    test name:
      let l = land(bytes)
      check l.error != ""

suite "starved":
  filter starved, c:
    let
      name = c.items[1].text
      bytes = c.items[2].bytes
    test name:
      let l = land(bytes)
      check l.error == ""
      check l.values.len == 0
      check l.pending

suite "reads":
  filter reads, c:
    let
      src = c.items[1].text
      value = c.items[2]
    test src.escape:
      check readValue(src) == value

suite "refuses":
  filter refuses, c:
    let src = c.items[1].text
    test src.escape:
      check reading(src) == refused

suite "incomplete":
  filter incomplete, c:
    let src = c.items[1].text
    test src.escape:
      check reading(src, whole = true) == incomplete

suite "document":
  filter document, c:
    let
      src = c.items[1].text
      values = c.items[2]
    test src.escape:
      check readDocument(src) == values.items.data

suite "derived":
  test "every case survives the JSON dialect":
    for c in cases:
      check c.toJson.toValue == c

  test "corpus.json is the cases":
    let records = parseJson(readFile(Corpus / "corpus.json"))
    check records.len == cases.len
    for i in 0 ..< min(records.len, cases.len):
      check records[i].toValue == cases[i]

  test "corpus.blb is the cases":
    let l = land(cast[seq[byte]](readFile(Corpus / "corpus.blb")))
    check l.error == ""
    check not l.pending
    check l.values.len == cases.len
    for i in 0 ..< min(l.values.len, cases.len):
      check l.values[i].toValue == cases[i]
