## Readings kept: what a value reads as in the host, read once.
##
## A reading takes a value to something the host holds, such as a seq of
## integers, a loaded struct, or a plan for doing it, and refuses what it
## can't hold. A value never changes once built, so neither does what it
## reads as: a reading kept against the value is as good as reading it
## again. One value may be read many ways at once, each kept by its own
## reading, and none puts another out.
##
## A frame's reading is kept against its body, which every copy of the
## frame shares, with its kind and mark, since a list and a record may
## share a body; so a value handed from doer to doer is read once however
## many hands it passes through. An atom's is kept against its CE. Two
## equal frames built apart are read apart, and that is only time lost.
##
## Only what a value reads as by itself is kept here. What doing it
## answers depends on where it is done, on variables and doers and sends,
## and is never kept against the value alone. What a reading answers is
## a copy of what it keeps; a reading of something large keeps a ref, so
## what it answers is shared by everyone who reads the value, and must
## never be changed. How much is kept, and when it is let go, is the
## reading's own affair.

import std/[sugar, tables]
import ../core

type
  Frame = tuple
    container: pointer
    kind: Kind
    mark: bool
  Reading*[T] = ref object
    ## a way to read values as T, keeping what each was read as
    name*: Value
    read: (Value) -> T
    frames: Table[Frame, (Value, T)]
      ## by body, kind and mark, since a list and a record may share a
      ## body; holding the value so its body lives as long
    atoms: Table[seq[byte], T]
    limit: int
    reads*: int ## how many values it has had to read

proc reading*[T](name: Value, read: (Value) -> T, limit = 1024): Reading[T] =
  ## values read by `read`, up to `limit` of each sort kept at once; past
  ## that, everything kept is let go and reading begins again
  Reading[T](name: name, read: read, limit: limit)

proc body(v: Value): pointer =
  case v.kind
  of bList, bRec: cast[pointer](v.items)
  of bDict: cast[pointer](v.dict)
  of bSet: cast[pointer](v.els)
  else: nil

proc `[]`*[T](r: Reading[T], v: Value): T =
  ## what v reads as, read once and then kept
  let b = v.body
  if b != nil:
    let key = (b, v.kind, v.mark)
    r.frames.withValue(key, kept):
      return kept[][1]
    result = r.read(v)
    inc r.reads
    if r.frames.len >= r.limit: r.frames.clear
    r.frames[key] = (v, result)
  else:
    let key = v.ce
    r.atoms.withValue(key, kept):
      return kept[]
    result = r.read(v)
    inc r.reads
    if r.atoms.len >= r.limit: r.atoms.clear
    r.atoms[key] = result

proc forget*(r: Reading) =
  ## let go of everything kept
  r.frames.clear
  r.atoms.clear