## fsnames: aliases as signed puts, read by the keys a reader trusts, and
## paths walked from what they name

import std/[unittest, options, os, sequtils]
import bl/[core, queries]
import bl/lib/[fs, fsnames, jam]
import bl/lib/crypto/clave

let scratch = getTempDir() / "tfsnames-" & $getCurrentProcessId()
removeDir(scratch)
createDir(scratch)

proc seed(n: byte): Keypair =
  var s: Seed
  for i in 0 ..< 32: s[i] = n
  keypairFromSeed(s)

let (alice, bob) = (seed(1), seed(2))

proc reader(): BVar[Value, Ranked[Value]] =
  spaceVar[Value, Ranked[Value]]()

var rank = 0
proc tell(local: BVar[Value, Ranked[Value]], put: Value) =
  ## keeps `put` as a jam would tell it, at the next rank
  let said = opened(put).get.said
  inc rank
  discard local.keep(initRec(@[said.items[0], toValue(rank), put]))

proc content(n: int): Value = digestOf(toValue(n))

let photos = text"photos"

suite "aliases":
  test "a name names what trusted keys said, the newest first, each once":
    let local = reader()
    local.tell alice.alias(photos, content(1))
    local.tell bob.alias(photos, content(2))
    local.tell alice.alias(photos, content(3))
    local.tell bob.alias(photos, content(1))
    check local.names(trusting([alice.pubkey, bob.pubkey]))[photos].toSeq ==
      @[content(1), content(3), content(2)]
    check local.names(trusting([alice.pubkey]))[photos].toSeq == @[content(3), content(1)]
    check local.names(trusting([]))[photos].toSeq.len == 0
    check local.aliasesOf(photos).mapIt(it.signer) ==
      @[bob.pubkey, alice.pubkey, bob.pubkey, alice.pubkey]

  test "what isn't a signed put of a digest to the name names nothing":
    let local = reader()
    let anyone = (k: Key) => true
    local.tell initRec(@[aliasQ(photos), content(1)])             # unsigned
    local.tell alice.alias(photos, toValue(4))                     # not a digest
    local.tell alice.alias(text"other", content(5))                # another name
    let elsewhere = alice.alias(text"other", content(6))
    inc rank
    discard local.keep(initRec(@[aliasQ(photos), toValue(rank), elsewhere]))  # told under photos
    check local.names(anyone)[photos].toSeq.len == 0
    check local.names(anyone)[text"other"].toSeq == @[content(5)]

suite "paths":
  let dir = scratch / "proj"
  createDir(dir / "src")
  writeFile(dir / "src" / "main.nim", "echo 1\n")
  writeFile(dir / "README", "hello\n")
  let k = openKeep(scratch / "keep.blb")
  let root = named(k.add(dir)).get
  let readme = named(k.add(dir / "README")).get
  let files = checked(keepSearch(k))
  let local = reader()
  local.tell alice.alias(text"proj", root)
  let names = local.names(trusting([alice.pubkey, bob.pubkey]))

  test "a path walks the trees from each digest its name names":
    let found = resolve(names, files, text"proj", ["src", "main.nim"]).toSeq
    check found.len == 1
    check FileEntry.fits(found[0])
    check files.bytesOf(named(found[0]).get).get == @(toOpenArrayByte("echo 1\n", 0, 6))
    check resolve(names, files, text"proj", []).toSeq == @[root]
    check resolve(names, files, root, ["README"]).mapIt(named(it).get).toSeq == @[readme]
    check resolve(names, files, text"proj", ["nothing"]).toSeq.len == 0
    check resolve(names, files, text"nobody", []).toSeq.len == 0

  test "each answer gives its own":
    local.tell bob.alias(text"proj", readme)
    let found = resolve(names, files, text"proj", []).toSeq
    check found == @[readme, root]
    check resolve(names, files, text"proj", ["README"]).toSeq.len == 1

  test "what a walk lacks is the first tree on the way it has no answer for":
    let src = named(resolve(names, files, root, ["src"]).toSeq[0]).get
    check files.lacking(root, ["src", "main.nim"]).len == 0
    check keepSearch(openKeep(scratch / "empty.blb")).lacking(root, ["src"]) == @[root]
    let rootOnly = newSearch[Value, Value]((d: Value) =>
      (if d == root: files.ask(d) else: empty(Value)))
    check rootOnly.lacking(root, ["src", "main.nim"]) == @[src]
    check rootOnly.lacking(root, ["README", "more"]).len == 0
    check rootOnly.lacking(root, []).len == 0

removeDir(scratch)
