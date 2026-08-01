import std/[unittest, os, options]
import pkg/core
import pkg/cmd/store

let root = getTempDir() / "bl-test-store-" & $getCurrentProcessId()
removeDir(root)

suite "content-addressed store":
  let s = openStore(root)
  let doc = toValue(
    BlFile(contents: toBytes"hello", info: some BlFileInfo(name: some "hello.txt"))
  )

  test "put returns the name; load round trips the CE bytes":
    let name = s.put(doc)
    check name == digest(doc)
    check name.algo == DigestAlgo # whatever `digest` names things with
    check name.hash == @(blake2b(doc))
    let raw = s.load(name)
    check raw.isSome
    check raw.get == encodeToString(doc)

  test "put is idempotent and convergent":
    let a = s.put(doc)
    let b = s.put(doc)
    check a == b
    var count = 0
    for _ in walkFiles(root / DigestAlgo / "*"):
      inc count
    check count == 1

  test "a name the store doesn't hold is none":
    var junk = newSeq[byte](32)
    junk[0] = 0xEE
    check s.load("sha256", junk).isNone

  test "a file that no longer matches its name is an error":
    let name = s.put(text"fragile")
    # sneak corruption in behind the store's back
    let target = encodeToString(text"fragile")
    for path in walkFiles(root / DigestAlgo / "*"):
      if readFile(path) == target:
        writeFile(path, "garbage")
        break
    expect StoreError:
      discard s.load(name)

  test "a value keeps its own algo, whatever the default is":
    # a name made another way is filed and found under that name's algo,
    # so a store may hold both without either shadowing the other
    let ce = encodeToString(text"older")
    let old = Digest(algo: Sym"sha256", hash: @(sha256(toValue text"older")))
    createDir(root / "sha256")
    writeFile(root / "sha256" / "x", "unused")
    check s.load(old).isNone # not filed yet, and the default didn't hide it
    check verifies(old, ce.toOpenArrayByte(0, ce.high))

  test "path-hostile algo names are refused":
    check not safeAlgo("../../../etc")
    check not safeAlgo("")
    check safeAlgo("sha256")
    expect StoreError:
      discard s.load("../escape", @[byte 1])

removeDir(root)
