import std/[unittest, options]
import pkg/core
import pkg/lib/[common, digest]
import pkg/lib/stores/memstore

suite "content-addressed store":
  let s = memoryStore()
  let doc = toValue(
    BlFile(contents: toBytes"hello", info: some BlFileInfo(name: some "hello.txt"))
  )

  test "put returns the name; load round trips the CE bytes":
    let name = s.put(doc)
    check name == digest(doc)
    check name.algo == DigestAlgo # whatever `digest` names things with
    check name.hash == @(blake2b(doc))
    let raw = s.get(name)
    check raw.isSome
    check encode(raw.get) == encode(doc)

  test "put is idempotent and convergent":
    let a = s.put(doc)
    let b = s.put(doc)
    check a == b
    var count = 0
    for d in s.stored():
      inc count
    check count == 1

  test "a name the store doesn't hold is none":
    var junk = Digest(algo: Sym"no-good", hash: newSeq[byte](32))
    check s.get(junk).isNone

  test "a value keeps its own algo, whatever the default is":
    let ce = encode text"older"
    let old = Digest(algo: Sym"sha256", hash: @(sha256 text"older"))
    check verifies(old, ce.toOpenArray(0, ce.high))
