## Moldable: a host object read from, and written as, one value. A
## struct's fields have names, and every struct is read and written by
## name (`moldFields`, `loadFields`); a value holds them either as a dict,
## `(HEAD {FIELD: VALUE …})`, or as a record in field order,
## `(HEAD VALUE …)`, and `mold` and `load` use the one its description
## names. What `moldable` generates is the type, its named reading and
## writing, and its shape; everything else here works from those.

import std/options
import ../core
export core, options

type
  MoldError* = object of BasslineError

  Rep* = enum
    repDict = "dict"     ## (HEAD {FIELD: VALUE …})
    repRecord = "record" ## (HEAD VALUE …), in field order

  Shape* = ref object
    ## what a struct's description says of the value as a whole
    head*: Value
    marked*: bool         ## its values are marked
    exact*: bool          ## a field or item more than described is refused
    rep*: Rep             ## the form `mold` writes and `load` reads
    names*: seq[Value]    ## its fields' names, in order
    optional*: seq[bool]  ## which of them may be left out
    description*: string  ## the struct, as described, in the textual syntax

  Moldable* = ref object of RootObj
    ## a host object read from, and written as, one value

refuseWith MoldError

method shape*(self: Moldable): Shape {.base.} =
  refuse "shape not implemented"

method moldFields*(self: Moldable): BDict {.base.} =
  ## the fields by name; an optional field with nothing in it is left out
  refuse "moldFields not implemented"

method loadFields*(self: Moldable, fields: BDict) {.base.} =
  ## the fields read by name. A field not described is left behind, or,
  ## read exactly, refused; an optional field not there is none. Nothing
  ## is set until every field is read
  refuse "loadFields not implemented"

method beforeMold*(self: Moldable) {.base.} =
  ## runs before self is written, each time: a place to put into its
  ## fields what they should say
  discard

method afterLoad*(self: Moldable) {.base.} =
  ## runs once, after self is first read from a value: a place to fill
  ## what is not written, or to refuse what the description can't
  discard

# ================ the two forms ================

func spelled(head: Value, mark: bool, rest: string): string =
  (if mark: "!(" else: "(") & $head & " " & rest & ")"

func absent(v: Value): bool =
  ## nil, where an optional field has nothing in it
  v.isKind(bNil) and not v.mark

proc fieldsOf*(s: Shape, v: Value, form: Rep): BDict =
  ## the fields v holds in `form`, by name, marked as described: the dict
  ## of `(HEAD {…})`, or the items of `(HEAD …)` in field order, nil
  ## where an optional field has nothing, and, read exactly, no more
  case form
  of repDict:
    guard v.isKind(bRec) and v.mark == s.marked and v.items.len == 2 and
      v.items[0] == s.head and v.items[1].isKind(bDict) and
      not v.items[1].mark, "not " & spelled(s.head, s.marked, "{…}")
    result = v.items[1].dict
  of repRecord:
    let n = s.names.len
    guard v.isKind(bRec) and v.mark == s.marked and
      (if s.exact: v.items.len == n + 1 else: v.items.len > n) and
      v.items[0] == s.head,
      "not " & spelled(s.head, s.marked, "…") & " with " &
      (if s.exact: "exactly " else: "") & $n & " items"
    result = newBDict()
    for i, name in s.names:
      let item = v.items[i + 1]
      if not (s.optional[i] and item.absent):
        result[name] = item

proc valueOf*(s: Shape, fields: BDict, form: Rep): Value =
  ## the fields written in `form`: `(HEAD {FIELD: VALUE …})`, or
  ## `(HEAD VALUE …)` in field order with nil, a stated absence, where an
  ## optional field has nothing in it
  case form
  of repDict:
    initRec(@[s.head, initDict(fields)], s.marked)
  of repRecord:
    var items = newSeqOfCap[Value](s.names.len + 1)
    items.add s.head
    for i, name in s.names:
      if name notin fields:
        items.add null()
      else:
        guard not (s.optional[i] and fields[name].absent),
          $name & " holds nil, which a record can't tell from nothing in it"
        items.add fields[name]
    initRec(items, s.marked)

# What `moldable` generates overrides these with code for one struct;
# here they work from `shape` and the named reading and writing, for a
# Moldable written by hand

method moldDict*(self: Moldable): Value {.base.} =
  ## `(HEAD {FIELD: VALUE …})`
  self.beforeMold()
  self.shape.valueOf(self.moldFields, repDict)

method loadDict*(self: Moldable, v: Value) {.base.} =
  self.loadFields(self.shape.fieldsOf(v, repDict))

method moldRec*(self: Moldable): Value {.base.} =
  ## `(HEAD VALUE …)`, in field order
  self.beforeMold()
  self.shape.valueOf(self.moldFields, repRecord)

method loadRec*(self: Moldable, v: Value) {.base.} =
  ## the items read as the fields in order; nil where an optional field
  ## is reads as none
  self.loadFields(self.shape.fieldsOf(v, repRecord))

method mold*(self: Moldable): Value {.base.} =
  ## the value, in the form its description names
  case self.shape.rep
  of repDict: self.moldDict
  of repRecord: self.moldRec

method load*(self: Moldable, v: Value) {.base.} =
  case self.shape.rep
  of repDict: self.loadDict(v)
  of repRecord: self.loadRec(v)

proc head*(self: Moldable): Value = self.shape.head
proc marked*(self: Moldable): bool = self.shape.marked
proc rep*(self: Moldable): Rep = self.shape.rep

# ================ by type ================

proc shape*[T: Moldable](_: type T): Shape = T().shape
proc head*[T: Moldable](_: type T): Value = T.shape.head
proc marked*[T: Moldable](_: type T): bool = T.shape.marked

# a Moldable made here is read for the first time, so `afterLoad` runs

template loader(name) =
  proc name*[T: Moldable](_: type T, v: Value): T =
    result = T()
    result.name(v)
    result.afterLoad()

loader load
loader loadDict
loader loadRec

proc loadFields*[T: Moldable](_: type T, fields: BDict): T =
  result = T()
  result.loadFields(fields)
  result.afterLoad()

proc fits*[T: Moldable](_: type T, v: Value): bool =
  ## whether T reads v, in its own form, by what its description says:
  ## `T.probe(v)`, which `moldable` generates, checks what `T.load(v)`
  ## would and builds nothing. `afterLoad` runs only on what is loaded,
  ## so what a hook refuses is heard only from a load
  mixin probe
  try:
    T.probe(v)
    true
  except MoldError:
    false

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
  ## a read as a B of its own, field by name: B's fields from a's, the
  ## rest of a left behind
  B.loadFields(a.moldFields)

proc `$`*(self: Moldable): string =
  $self.mold
