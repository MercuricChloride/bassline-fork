##[
  A random value generator for bassline.
  Blah blah blah..
]##

import std/random
import ../core

proc randValue*(depth = 0): Value

proc randAtom*(maxLength = 100): Value =
  let
    kind: range[bNil..bBytes] = rand(bNil..bBytes)
    mark = bool.rand
  case kind
  of bNil:
    null(mark)
  of bNum:
    num(int64.rand, mark)
  of bText, bSym:
    let r = rand(100)
    var s = newString(r)
    for i in 0..s.high:
      s[i] = char rand(33..127)
    if kind == bText:
      text(s, mark)
    else:
      sym(s, mark)
  of bBytes:
    var b = newSeq[byte](rand(maxLength))
    for i in 0..b.high:
      b[i] = rand(byte)
    bytes(b, mark)

proc randFrame*(depth = 0): Value =
  let
    max = 20
    kind: range[bList..bSet] = rand(bList..bSet)
    mark = bool.rand
  case kind
  of bList:
    let n = rand(max)
    var items = newSeq[Value](n)
    for i in 0..<n:
      items[i] = randValue(depth + 1)
    initList(items, mark)
  of bRec:
    let n = rand(1..max)
    var items = newSeq[Value](n)
    for i in 0..<n:
      items[i] = randValue(depth + 1)
    initRec(items, mark)
  of bDict:
    let n = rand(max)
    var d = initDict(mark)
    for _ in 0..<n:
      d.dict[randValue(depth + 1)] = randValue(depth + 1)
    d
  of bSet:
    let n = rand(max)
    var s = initSet(mark)
    for _ in 0..<n:
      s.els.incl randValue(depth + 1)
    s

proc randValue*(depth = 0): Value =
  if depth > 5:
    return randAtom()
  
  if rand(bool):
    randAtom()
  else:
    randFrame(depth)

iterator blah*(count: Natural = 10): Value =
  for _ in 0..<count:
    yield randValue()