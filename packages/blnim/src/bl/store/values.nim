import ../core
import ./store

proc frameKey(q: ValueView): seq[byte] =
  ## The byte-prefix key that selects exactly the values `q` prefixes
  ## (see `queries.prefixes`): `q`'s CE bytes with one trailing ENDs.
  ## A scalar `q` yields its bytes unchanged
  var v = q
  var opens = 0
  while v.kind in {bList, bRec, bDict, bSet}:
    inc opens
    if v.kind == bDict:
      let es = v.entries
      if es.len == 0 or es[es.len - 1].val.isNil: break
      v = es[es.len - 1].val
    else:
      let cs = v.children
      if cs.len == 0: break
      v = cs[cs.len - 1]
  result = @(q.bytes)
  result.setLen(result.len - opens)

proc frameKey(q: Value): seq[byte] =
  ## `frameKey` for an in-memory value: through its view.
  frameKey(q.toView)

proc incl*[A](db: Db[A]; v: Value): bool {.discardable.} =
  db.incl v.ce

proc incl*[A](db: Db[A]; v: ValueView): bool {.discardable.} =
  db.incl v.ce

proc contains*[A](s: Snapshot[A], v: Value): bool = 
  v.ce in s

proc contains*[A](s: Snapshot[A], v: ValueView): bool =
  v.ce in s

proc contains*[A](db: Db[A], v: Value): bool = 
  v.ce in db

proc contains*[A](db: Db[A], v: ValueView): bool =
  v.ce in db

iterator items*[A](s: Snapshot[A]): ValueView =
  for e in s.scan():
    yield ValueView.decode(e)

iterator itemsFrom*[A](s: Snapshot[A]; lo: openArray[byte]): ValueView =
  ## Elements whose CE bytes are >= `lo`
  var c = s.newCursorAt(lo)
  while c.isValid:
    yield ValueView.decode(c.current())
    c.advance()

iterator itemsFrom*[A](s: Snapshot[A]; lo: ValueView): ValueView =
  var c = s.newCursorAt(lo.bytes)
  while c.isValid:
    yield ValueView.decode(c.current())
    c.advance()

iterator itemsFrom*[A](s: Snapshot[A]; lo: Value): ValueView =
  var c = s.newCursorAt(ce lo)
  while c.isValid:
    yield ValueView.decode(c.current())
    c.advance()

iterator under*[A](s: Snapshot[A]; key: openArray[byte]): ValueView =
  ## Every element whose CE bytes extend `key` (a `frameKey`)
  for e in s.scan(key):
    yield ValueView.decode(e)

iterator under*[A](s: Snapshot[A], key: Value): ValueView =
  let key = frameKey(key)
  for view in s.under(key):
    yield view

iterator under*[A](s: Snapshot[A], key: ValueView): ValueView =
  let key = frameKey(key)
  for view in s.under(key):
    yield view

template boundView[T](Type: typedesc[T], b: untyped, which: string): T =
  if b.len == 0: raise newException(KeyError, which & " on an empty store")
  T.decode(b)

proc low*[T,K](_: typedesc[T], s: K): T = boundView(T, s.low, "low")
proc high*[T,K](_: typedesc[T], s: K): T = boundView(T, s.high, "high")