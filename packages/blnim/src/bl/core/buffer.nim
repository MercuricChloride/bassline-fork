type
  Buffer*[T] {.acyclic.} = ref object
   data*: seq[T]

func newBuffer*[T](len: Natural = 0): Buffer[T] =
  Buffer[T](data: newSeq[T](len))

func newBuffer*[T](data: sink seq[T]): Buffer[T] =
  Buffer[T](data: data)

func newBuffer*[T](data: openArray[T]): Buffer[T] =
  newBuffer(@data)

func newBufferOfCap*[T](cap: Natural): Buffer[T] =
  newBuffer(newSeqOfCap[T](cap))

func len*(buf: Buffer): Natural =
  buf.data.len

func `[]`*[Idx, T](buf: Buffer[T], i: Idx): lent T =
  buf.data[i]

proc `[]=`*[Idx, T](buf: Buffer[T], i: Idx, val: T) =
  buf.data[i] = val

proc add*[T](buf: Buffer[T], item: T) =
  buf.data.add item

proc add*[T](buf: Buffer[T], items: openArray[T]) =
  buf.data.add items

iterator items*[T](buf: Buffer[T]): lent T =
  for v in buf.data:
    yield v

iterator pairs*[T](buf: Buffer[T]): (Natural, lent T) =
  for i, v in buf.data:
    yield (i, v)

iterator mitems*[T](buf: Buffer[T]): var T =
  for v in buf.data.mitems:
    yield v

iterator mpairs*[T](buf: Buffer[T]): (Natural, var T) =
  for i, v in buf.data.mpairs:
    yield (i, v)

# ================ Cursor ================

type
  BufferStarvedError* = object of CatchableError

  Cursor*[T] = object
    buf*: Buffer[T]
    pos*: Natural

template starved*(msg: string) =
  raise newException(BufferStarvedError, msg)

func initCursor*[T](buf: Buffer[T]): Cursor[T] =
  Cursor[T](buf: buf, pos: 0)