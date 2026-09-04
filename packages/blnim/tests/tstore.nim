## the store holds spelled values in value order: a scan hands back
## exactly the values sorted by `cmp`, spelled, on both backends,
## byte-identically

import std/[algorithm, os, unittest]
import bl/core
import bl/store/store
import bl/lib/blah
import ./corpus

# the elements: every corpus value, and random ones

var values: seq[Value]
filter ce, c:
  values.add c.items[2]
for _ in 0 ..< 500:
  values.add randValue(3)

var ordered = values
ordered.sort(cmp)
var i = 1
while i < ordered.len:                      # the store is a set
  if ordered[i] == ordered[i - 1]: ordered.delete(i)
  else: inc i

var expect: seq[seq[byte]]
for v in ordered:
  expect.add ceBytes(v)

proc holds[A](db: Db[A]) =
  ## db, after every element went in, scans as the values in order
  db.withTx:
    for v in values:
      discard db.insert(ceBytes(v))
  var got: seq[seq[byte]]
  for e in db.scan():
    got.add e
  check got == expect
  let snap = db.snapshot()
  for v in values:
    check snap.member(ceBytes(v))
  check not snap.member(ceBytes(sym"not-in-the-store"))
  # what the store hands back in place is a value the codec accepts
  var cur = snap.newCursorAt(expect[0])
  var n = 0
  while cur.isValid:
    if cur.currentIsInline:
      let (p, len) = cur.currentSpan()
      let l = land(toOpenArray(p, 0, len - 1))
      check not l.refused
      check l.values.len == 1
      inc n
    cur.advance()
  check n > 0

suite "backends":
  let
    memPath = getTempDir() / "bl_tstore_mem.db"
    filePath = getTempDir() / "bl_tstore_file.db"
  removeFile(memPath)
  removeFile(filePath)

  test "memory":
    var mem = createMemDb()
    holds(mem)
    mem.dump(memPath)
    mem.close()

  test "mmap":
    var fdb = createDb(filePath)
    holds(fdb)
    fdb.close()

  test "byte-identical pages":
    check readFile(memPath) == readFile(filePath)

  test "the file reopens to the same set":
    var back = openDb(filePath)
    var again: seq[seq[byte]]
    for e in back.scan(): again.add e
    check again == expect
    back.close()
    removeFile(memPath)
    removeFile(filePath)
