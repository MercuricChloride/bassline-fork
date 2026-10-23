## the shared corpus's CE cases, run against both value types: one suite
## per case head, one test per case. The text cases are for the bracket
## syntax, which tinybl doesn't read.

import std/[streams, os, unittest]
import tinybl

const Corpus = currentSourcePath().parentDir.parentDir.parentDir.parentDir / "corpus"

var
  r: TypeReader[ValueObj]
  cases: seq[ValueObj]
let s = newStringStream(readFile(Corpus / "corpus.blb"))
while s.readStream(r): 
  cases.add move r.value
doAssert not r.starved

template filter*(head: string, c, body: untyped) =
  for c in cases:
    if c.items[0].text == head:
      body

type Landed[T] = object
  values: seq[T]
  refused, starved: bool

proc land[T](bytes: string): Landed[T] =
  ## what reading bytes given in total lands, and how it ends
  let s = newStringStream(bytes)
  var r: TypeReader[T]
  try:
    while s.readStream(r):
      when T is RawValue:
        r.value.validate
        if not r.value.valid:
          result.refused = true
          return
      result.values.add move r.value
  except BasslineError:
    result.refused = true
  result.starved = r.starved

template landsOnly(landed: Landed, bytes: string) =
  ## lands one value, the one bytes spell, and nothing waits
  let l = landed
  check not l.refused
  check l.values.len == 1 and l.values[0].ce == bytes
  check not l.starved

template waits(landed: Landed) =
  ## refuses nothing and lands nothing, waiting on more
  let l = landed
  check not l.refused
  check l.values.len == 0
  check l.starved

suite "ce":
  filter "ce", c:
    let
      value = c.items[2]
      bytes = c.items[3].bytes
    test c.items[1].text:
      check value.ce == bytes
      landsOnly land[ValueObj](bytes), bytes
      landsOnly land[RawValue](bytes), bytes

suite "reject":
  filter "reject", c:
    let bytes = c.items[2].bytes
    test c.items[1].text:
      check land[ValueObj](bytes).refused
      check land[RawValue](bytes).refused

suite "starved":
  filter "starved", c:
    let bytes = c.items[2].bytes
    test c.items[1].text:
      waits land[ValueObj](bytes)
      waits land[RawValue](bytes)