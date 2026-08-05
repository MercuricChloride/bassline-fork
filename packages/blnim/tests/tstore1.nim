import std/[unittest, options, os, sets, tempfiles]
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

  test "entries file under the front of the name":
    let name = fs.put(doc)
    let hex = hexName(name.hash)
    check fileExists(root / $name.algo / hex[0 .. 2] / hex[3..high(hex)])

  test "get verifies what the disk says before vouching for it":
    let name = fs.put(doc)
    let hex = hexName(name.hash)
    let path = root / $name.algo / hex[0 .. 2] / hex[3 .. high(hex)]
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
    let hex = hexName(name.hash)
    let shard = root / $name.algo / hex[0 .. 2]
    writeFile(root / $name.algo / ".DS_Store", "junk")
    writeFile(shard / hex[3 .. high(hex)] & ".tmp999", "junk")

    writeFile(root / $name.algo / "ab".repeat(32), "junk")
    createDir(root / $name.algo / hex[0 .. 3])
    writeFile(root / $name.algo / hex[0 .. 3] / hex[4 .. high(hex)], "junk")
    var found: seq[Digest]
    for d in fs.stored():
      found.add d
    check found == @[name]

  test "stored walks every shard and agrees with has":
    let base = createTempDir("blstore", "")
    let fresh = base / "deep" / "root"
    let many = fileStore(fresh)
    check many.get(digest(doc)).isNone # an absent root is a miss, not an error
    check not dirExists(fresh) # speaking of a store creates nothing
    var wanted: HashSet[string]
    for i in 0 ..< 40:
      wanted.incl hexName(many.put(text("v" & $i)).hash)
    var found: HashSet[string]
    var yields = 0
    for d in many.stored():
      inc yields
      found.incl hexName(d.hash)
      check many.has(d) # stored never vouches for what has denies
    check yields == 40
    check found == wanted
    removeDir(base)

  test "a root that isn't a directory holds nothing":
    let base = createTempDir("blstore", "")
    writeFile(base / "blocker", "")
    let blocked = fileStore(base / "blocker")
    check not blocked.has(digest(doc))
    check blocked.get(digest(doc)).isNone
    removeDir(base)

  removeDir(root)
