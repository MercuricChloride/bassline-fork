import ../core
import ./mold

type
  PolyError* = object of BasslineError
  Poly* = ref object
    ## fields, by name, read through whichever Moldable face is asked
    ## for. The fields are what every face has written, the live one
    ## written over the rest: a field the live face describes is the
    ## face's to say, so one it leaves out is left out. A face is one
    ## reading of them, and only the one last asked for is live: a face
    ## handed out before it is no longer heard from.
    fields: BDict
    face: Moldable

refuseWith PolyError

proc poly*(self: Moldable): Poly =
  Poly(fields: newBDict(), face: self)

proc poly*(self: BDict): Poly =
  guard self != nil, "poly of a nil dict"
  Poly(fields: self)

proc poly*(self: Value): Poly =
  ## a poly of fields by name, as an unmarked dict
  guard self.isKind(bDict) and not self.mark,
    "a poly holds fields by name, as an unmarked dict"
  Poly(fields: self.dict)

proc flush(self: Poly) =
  ## the live face's fields written over the rest, its own fields wholly
  ## its to say; a new tree, so a dict the poly was made from never
  ## changes underneath its owner
  if self.face == nil: return
  let described = self.face.shape.names
  var kept = newBDict()
  for name, v in self.fields:
    if name notin described:
      kept[name] = v
  self.fields = kept + self.face.moldFields

proc morph*[A: Moldable](self: Poly, _: type A): A =
  ## the fields read as an A, now the live face
  if self.face != nil and self.face of A:
    return A(self.face)
  self.flush
  result = A.loadFields(self.fields)
  self.face = result

proc toDict*(self: Poly): Value =
  ## every field, by name, the live face's written over the rest
  self.flush
  initDict(self.fields)

proc toValue*(self: Poly): Value =
  ## every field, under the live face's head; the bare fields while no
  ## face has been asked for. A face written as a record has a place for
  ## its own fields only, so it is written as it molds
  self.flush
  if self.face == nil:
    initDict(self.fields)
  elif self.face.rep == repRecord:
    self.face.moldRec
  else:
    initRec(@[self.face.head, initDict(self.fields)], mark = self.face.marked)

proc `[]`*[A: Moldable](self: Poly, _: type A): A =
  self.morph(A)

proc `[]`*(self: Poly, _: type Value): Value =
  self.toValue
