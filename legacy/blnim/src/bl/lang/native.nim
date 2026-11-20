## Natives: doers written in the host, each described by a struct.
##
## A native's description is a marked struct, so its calls are the
## marked records it molds: `!(struct add {exact (rep record)} (a number)
## (b number))` does `!(add 1 2)`. The description is its signature, a
## value anyone can ask for (`describe`): its head names it, its fields
## are its parameters, `(rep record)` takes them by position and `(rep
## dict)` by name, as `!(HEAD !{NAME: ARG …})`, the dict marked so that
## what is in it is worked out (an unmarked one is handed over as said),
## `{optional}` may be left out, and `exact` refuses an argument more. A
## list parameter takes any number of values, and a dict one any names.
##
## A call reaches a native with its direct marked arguments already
## done, so binding is loading: the native fits a call its struct reads,
## by its probe, and is given the object loaded from it, through `run`.
## A struct read by position takes its trailing optional parameters left
## out as nothing in them. What doesn't fit is passed on to the next doer
## in reach; what the struct reads but `afterLoad` or `run` refuses is
## refused.

import ../mold
import ./kernel
export mold, kernel

refuseWith BasslineError

type Native* = ref object of Doer
  ## a struct's calls, done by its `run`
  shape: mold.Shape
  probe: (Value) -> void
  load: (Value) -> Moldable

method run*(self: Moldable, cx: Cx): Stream[Value] {.base.} =
  ## what the call self was loaded from answers, done in cx
  refuse $self.shape.head & " has nothing to run"

proc padded(s: mold.Shape, v: Value): Value =
  ## a call by position with trailing optional parameters left out, each
  ## read as nothing in it
  result = v
  if s.rep != repRecord or not v.isKind(bRec) or v.items.len > s.names.len:
    return
  var items = v.items.data
  for i in items.len - 1 ..< s.names.len:
    if not s.optional[i]: return
    items.add null()
  result = initRec(items, v.mark)

proc native*[T: Moldable](_: type T): Native =
  ## T's calls, done by T's `run`
  mixin probe
  Native(shape: T.shape,
         probe: (v: Value) => T.probe(v),
         load: (v: Value) -> Moldable => T.load(v))

method fits*(d: Native, v: Value): bool =
  try:
    d.probe(d.shape.padded(v))
    true
  except MoldError:
    false

method answers*(d: Native, v: Value, cx: Cx): Stream[Value] =
  d.load(d.shape.padded(v)).run(cx)

method describe*(d: Native): Value =
  readValue(d.shape.description)

proc install*(cx: Cx, natives: varargs[Native]) =
  ## each native found here by its head
  for n in natives:
    cx.install(n.shape.head, n)
