## bl fs: files into the keep, names on the jam, and what the keep lacks
## fetched from a keeper

import std/sugar
import cli
import bl/lib/fs

doAssert fileExists(bin / "bl-fs"), "build first: nim build"

proc keygen(name: string): tuple[path: string, pub: Value] =
  ## a keypair kept in tmp, and its public key as bytes
  let path = tmp / (name & ".key")
  if not fileExists(path): doAssert sh("bl clave keygen --out " & path).code == 0
  let kp = Keypair.fromValue(decoded(readFile(path))[0])
  (path, bytes(@(kp.pubkey)))

proc keeper(s: Serving, keep, name, key: string): Process =
  startProcess(bin / "bl-jam", args = @["keep", "--at", ":" & s.port, "--as", name,
                                       "--keep", keep, "--key", key], options = {})

proc stopKeeper(p: Process) =
  discard kill(Pid(p.processID), SIGTERM)
  discard p.waitForExit
  p.close()

proc tree(name: string): string =
  ## a directory with a small file, a large one and a directory in it
  result = tmp / name
  createDir(result / "src")
  writeFile(result / "README", "hello\n")
  writeFile(result / "src" / "main.nim", "echo 1\n")
  var big = newString(200_000)
  var x = 7'u32
  for c in big.mitems:
    x = x * 1664525 + 1013904223
    c = char(x shr 24)
  writeFile(result / "src" / "big.bin", big)

let (alice, alicePub) = keygen("alice")
let (bob, _) = keygen("bob")

suite "fs":
  test "add files a tree into the keep and says what it was added as":
    let dir = tree("added")
    let r = sh("bl fs add " & dir & " --keep " & tmp / "added.blb")
    check r.code == 0
    let said = decoded(r.output)
    check said.len == 1 and said[0].head == sym"added" and said[0].items[1] == text(dir)
    let k = openKeep(tmp / "added.blb")
    check keepSearch(k).missing(said[0].items[2]).len == 0
    k.close()

  test "an alias is read back by the keys trusted, and listed under aliases":
    let jam = jamServe()
    let d = digestOf(text"anything")
    let put = sh("bl fs alias proj '" & $d & "' --key " & alice & " --at :" & jam.port)
    check put.code == 0
    check decoded(put.output) == @[readValue("(put (alias \"proj\") 1)")]
    let mine = sh("bl fs alias proj --key " & alice & " --at :" & jam.port)
    check decoded(mine.output) == @[initRec(@[sym"alias", text"proj", d, alicePub])]
    check decoded(sh("bl fs alias proj --key " & bob & " --at :" & jam.port).output).len == 0
    check decoded(sh("bl fs alias proj --key " & bob & " --trust " & $alicePub & " --at :" &
                     jam.port).output) == decoded(mine.output)
    check decoded(sh("bl fs alias proj --key " & bob & " --anyone --at :" & jam.port).output) ==
      decoded(mine.output)
    var heard: seq[Value]
    let line = jam.asking(blb("(aliases)"))
    line.hearUntil(heard, (vs: seq[Value]) => vs.len > 0)
    check heard.anyIt(heard(it).isSome and heard(it).get.said == text"proj")
    line.close()
    discard jam.stop

  test "get, ls and cat fetch what the keep lacks from a keeper, and keep it":
    # one person's keeper and bl fs, signing with one key
    let dir = tree("shared")
    let jam = jamServe()
    let at = " --at :" & jam.port & " --key " & alice & " --wait 10"
    check sh("bl fs add " & dir & " --alias shared --keep " & tmp / "a.blb" & at).code == 0
    let k = jam.keeper(tmp / "a.blb", "ka", alice)
    let into = " --keep " & tmp / "b.blb"
    let ls = sh("bl fs ls shared/src" & into & at)
    check ls.code == 0
    check decoded(ls.output).mapIt(it.items[1]) == @[text"big.bin", text"main.nim"]
    let cat = sh("bl fs cat shared/src/main.nim" & into & at)
    check cat.code == 0 and cat.output == "echo 1\n"
    let get = sh("bl fs get shared " & tmp / "got" & into & at)
    check get.code == 0
    check sh("diff -r " & dir & " " & tmp / "got").code == 0
    k.stopKeeper()
    # what was fetched is kept, so it is there with no keeper
    check sh("bl fs cat shared/README" & into & at).output == "hello\n"
    discard jam.stop

  test "what nobody gives is said lacking, and a directory is not a file":
    let jam = jamServe()
    let at = " --at :" & jam.port & " --key " & alice & " --wait 1"
    let nobody = digestOf(text"held by no one")
    let r = sh("bl fs get '" & $nobody & "' " & tmp / "none" & at)
    check r.code == 1
    check ("lacking " & $nobody) in r.errors
    check not fileExists(tmp / "none")
    let dir = tree("plain")
    check sh("bl fs add " & dir & " --alias plain --keep " & tmp / "p.blb" & at).code == 0
    check sh("bl fs cat plain --keep " & tmp / "p.blb" & at).code == 1
    check sh("bl fs ls nothing --keep " & tmp / "p.blb" & at).code == 1
    discard jam.stop
