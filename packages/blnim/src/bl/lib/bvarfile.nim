## BVars kept in files.
##
## A file var's file holds one value: the var's space, written down as
## an object, `!{!(kind search-space) (identity ID) (holds {…})}` (a
## dict in `holds` for one answer a query, `!(kind ranked)` for ranked
## answers). It is rewritten whole each time the var takes something,
## through a fresh file renamed over the old, so the file is always the
## space as it stood after some send, readable by anything that reads CE.
##
## A log var's file is a bare concatenation of the records it has taken,
## each appended as it takes it, so keeping it costs one record however
## much it holds; opened again, it holds every record in the file.

import std/os
import ../[core, queries]

refuseWith BasslineError

proc valueIn*(path: string): Value =
  ## the one value in the file at `path`. Refuses bytes that aren't
  ## exactly one value in CE
  let bytes = readFile(path)
  try:
    Value.decode(bytes.toOpenArrayByte(0, bytes.high))
  except CodecError as e:
    refuse path & " is not one CE value: " & e.msg

proc writeValue*(path: string, v: Value): bool =
  ## writes `v`'s CE as the whole file at `path`, through a fresh file
  ## beside it renamed over the old, answering whether it was written
  let fresh = path & ".new"
  try:
    writeFile(fresh, v.ce.toString)
    moveFile(fresh, path)
    true
  except OSError, IOError:
    false

proc appendValue*(path: string, v: Value): bool =
  ## appends `v`'s CE to the file at `path`, answering whether it was
  ## written
  try:
    let f = open(path, fmAppend)
    defer: f.close()
    f.write v.ce.toString
    f.flushFile()
    true
  except OSError, IOError:
    false

proc valuesIn*(path: string, mend = true): seq[Value] =
  ## every value in the file at `path`, a bare concatenation of CE. A
  ## last value cut short, as by a crash partway through appending it,
  ## is cut from the file, so what is appended next starts clean, unless
  ## `mend` is false: a reader that doesn't append to the file leaves it
  ## as it is, since whoever does may be partway through. Refuses bytes
  ## that break the grammar
  let bytes = readFile(path)
  var
    d = newDecoder(newBuffer(bytes.toOpenArrayByte(0, bytes.high)))
    whole = 0   # where the last whole value ends
  try:
    for v in d.checked:
      result.add v.toValue
      whole = v.offset + v.len
  except CodecError as e:
    refuse path & " is not a run of CE values: " & e.msg
  if mend and whole < bytes.len:
    writeFile(path, bytes[0 ..< whole])

proc logVar*[Q, A](path: string, id = randomId(), skipRefused = false):
    BVar[Q, A] =
  ## a space var, any number of answers a query, kept as a log in the
  ## file at `path`: each record it takes is appended, and an existing
  ## file is every record it holds, going by `id`
  let records = if fileExists(path): valuesIn(path) else: @[]
  let kinds = when A is Ranked: @[SearchSpaceKind, RankedKind]
              else: @[SearchSpaceKind]
  let held = spaceVar[Q, A](
    describe(kinds, id, initRec(@[HoldsQ, initSet(records)])), skipRefused)
  let inner = held.sender
  proc send(q: Q, a: A): bool =
    # kept, then taken: what the file doesn't hold, the place doesn't
    appendValue(path, record(q, a)) and inner.send(q, a)
  newBVar(newSend(send, k(sendTo(id))), held.search, id)

proc fileVar*[Q, A](path: string, fanout = many, id = randomId(),
                    skipRefused = false): BVar[Q, A] =
  ## a space var kept in the file at `path`. An existing file is the var
  ## itself, by its own ID and fan-out; a new one starts as the empty
  ## space made from `fanout` and `id`
  let held =
    if fileExists(path):
      spaceVar[Q, A](valueIn(path), skipRefused)
    else:
      let v = spaceVar[Q, A](fanout, id, skipRefused)
      guard writeValue(path, v.search.toValue), "can't write " & path
      v
  held.persist(space => writeValue(path, space))