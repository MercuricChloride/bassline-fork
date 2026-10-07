import std/options
import ../core
export core, options

type
  MoldError* = object of BasslineError
  Moldable* = ref object of RootObj
    ## a host object written as, and read from, one value

refuseWith MoldError

method mold*(self: Moldable): Value {.base.} =
  refuse "mold not implemented"

method load*(self: Moldable, v: Value) {.base.} =
  refuse "load not implemented"

method moldHeadless*(self: Moldable): Value {.base.} =
  ## what `mold` writes, without the head: the fields as an unmarked
  ## dict, or the items, in order, as an unmarked list
  refuse "moldHeadless not implemented"

method moldFields*(self: Moldable): BDict {.base.} =
  ## the fields by name, however `mold` writes them
  refuse "moldFields not implemented"

method positional*(self: Moldable): bool {.base.} =
  ## whether self is described by items rather than by fields
  false

method head*(self: Moldable): Value {.base.} =
  ## the head `mold` writes self under
  refuse "head not implemented"

method marked*(self: Moldable): bool {.base.} =
  ## whether `mold` writes self marked
  refuse "marked not implemented"

method loadHeadless*(self: Moldable, v: Value) {.base.} =
  ## `load` from what `moldHeadless` writes, whatever head it came
  ## under: the fields by name from an unmarked dict, or, for a type
  ## described by items, the items by place from an unmarked list. Only
  ## what is described is read; any other field, or any item past the
  ## last described, is left behind.
  refuse "loadHeadless not implemented"

proc load*[T: Moldable](_: type T, v: Value): T =
  result = T()
  result.load(v)

proc loadHeadless*[T: Moldable](_: type T, v: Value): T =
  result = T()
  result.loadHeadless(v)

proc maybeLoad*[T: Moldable](_: type T, v: Value): Option[T] =
  try:
    some T.load(v)
  except MoldError:
    none T

proc toValue*(self: Moldable): Value =
  self.mold

proc fromValue*[T: Moldable](_: typedesc[T], v: Value): T =
  T.load(v)

proc convert*[A, B: Moldable](a: A, _: type B): B =
  ## a read as a B of its own: B's fields by name from a's, or, when
  ## both are described by items, B's items by place from a's. The rest
  ## of a is left behind
  result = B()
  if a.positional and result.positional:
    result.loadHeadless(a.moldHeadless)
  else:
    result.loadHeadless(initDict(a.moldFields))

proc `$`*(self: Moldable): string =
  $self.mold