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
    check name.algo == "sha256"
    check name.hash == @(sha256(doc))
    let raw = s.load(name)
    check raw.isSome
    check raw.get == encodeToString(doc)

  test "put is idempotent and convergent":
    let a = s.put(doc)
    let b = s.put(doc)
    check a == b
    var count = 0
    for _ in walkFiles(root / "sha256" / "*"):
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
    for path in walkFiles(root / "sha256" / "*"):
      if readFile(path) == target:
        writeFile(path, "garbage")
        break
    expect StoreError:
      discard s.load(name)

  test "path-hostile algo names are refused":
    check not safeAlgo("../../../etc")
    check not safeAlgo("")
    check safeAlgo("sha256")
    expect StoreError:
      discard s.load("../escape", @[byte 1])

removeDir(root)
