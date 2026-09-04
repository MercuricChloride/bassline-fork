## the store holds spelled values in exactly the codec's byte order,
## on both backends, byte-identically
import std/[algorithm, os]
import pkg/store
import pkg/core/[codec, reader]
import ./corpus

let cs = cases()
var elems: seq[seq[byte]]
for c in cs:
  elems.add c.bytes
var g = initValueGen(5)
for _ in 0 ..< 500:
  elems.add spell(g.genValue(3))

var expect = elems
expect.sort(proc(a, b: seq[byte]): int = codec.cmpBytes(a, b))
var i = 1
while i < expect.len:                       # the store is a set
  if expect[i] == expect[i - 1]: expect.delete(i)
  else: inc i

proc check[A](db: Db[A], label: string) =
  db.withTx:
    for e in elems:
      discard db.insert(e)
  var got: seq[seq[byte]]
  for e in db.scan():
    got.add e
  doAssert got == expect, label & ": scan order is not cmpBytes order"
  let snap = db.snapshot()
  for c in cs:
    doAssert snap.member(c.bytes), label & ": " & c.name
  doAssert not snap.member(spell(sym("not-in-the-store")))
  var c2 = snap.newCursorAt(cs[0].bytes)  # zero-copy spans judge clean
  var n = 0
  while c2.isValid:
    if c2.currentIsInline:
      let (p, len) = c2.currentSpan()
      judge(toOpenArray(p, 0, len - 1))
      inc n
    c2.advance()
  doAssert n > 0

# the store's own byte order is the codec's
for a in cs:
  for b in cs:
    doAssert (store.cmpBytes(a.bytes, b.bytes) < 0) == (codec.cmpBytes(a.bytes, b.bytes) < 0)

var mem = createMemDb()
check(mem, "mem")
let memPath = "/tmp/bl_tstore_mem.db"
removeFile(memPath)
mem.dump(memPath)

let filePath = "/tmp/bl_tstore_file.db"
removeFile(filePath)
var fdb = createDb(filePath)
check(fdb, "file")
doAssert fdb.pages == mem.pages
fdb.close()
mem.close()
doAssert readFile(memPath) == readFile(filePath), "backends produced different pages"

# and the file reopens to the same set
var back = openDb(filePath)
var again: seq[seq[byte]]
for e in back.scan(): again.add e
doAssert again == expect
back.close()
removeFile(memPath)
removeFile(filePath)

echo "tstore ok"
