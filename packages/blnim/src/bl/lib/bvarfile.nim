## BVars kept in files.
##
## A file var's file holds one value: the var's space, written down as
## an object, `!{!(kind search-space) (identity ID) (holds {…})}` (a
## dict in `holds` for one answer a query, `!(kind ranked)` for ranked
## answers). It is rewritten whole each time the var takes something,
## through a fresh file renamed over the old, so the file is always the
## space as it stood after some send, readable by anything that reads CE.

import std/os
import ../[core, queries]

refuseWith ValueError

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
  held.persist(proc(space: Value): bool = writeValue(path, space))
