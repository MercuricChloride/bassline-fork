import std/[unittest, options, os, tempfiles]
import pkg/core
import pkg/lib/common
import pkg/lib/crypto/digest
import pkg/lib/stores/[memstore, filestore, util]

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

suite "file store":
  let root = createTempDir("blstore", "")
  let fs = fileStore(root)
  let doc = toValue(
    BlFile(contents: toBytes"hello", info: some BlFileInfo(name: some "hello.txt"))
  )

  test "put then get round trips through disk":
    let name = fs.put(doc)
    check name == digest(doc)
    check fs.has(name)
    let back = fs.get(name)
    check back.isSome
    check encode(back.get) == encode(doc)

  test "get verifies what the disk says before vouching for it":
    let name = fs.put(doc)
    let path = root / $name.algo / hexName(name.hash)
    var raw = readFile(path)
    raw[raw.high] = char(raw[raw.high].byte xor 0xff)
    writeFile(path, raw)
    expect ValueError:
      discard fs.get(name)
    writeFile(path, encode(doc)) # restore for the suite's other tests

  test "a digest the store can't verify is not an address":
    # a hostile algo never becomes a path
    let evil = Digest(algo: Sym"../../evil", hash: newSeq[byte](DigestBytes))
    check not fs.has(evil)
    check fs.get(evil).isNone
    # an unknown algo of innocent spelling isn't held either
    let odd = Digest(algo: Sym"md5", hash: newSeq[byte](DigestBytes))
    check not fs.has(odd)
    check fs.get(odd).isNone
    # a known algo with a hash of the wrong size isn't held
    let short = Digest(algo: Sym"blake2b", hash: @[byte 1, 2, 3])
    check not fs.has(short)
    check fs.get(short).isNone

  test "stored skips what isn't an entry":
    let name = fs.put(doc)
    writeFile(root / $name.algo / ".DS_Store", "junk")
    writeFile(root / $name.algo / hexName(name.hash) & ".tmp999", "junk")
    var found: seq[Digest]
    for d in fs.stored():
      found.add d
    check found == @[name]

  removeDir(root)
