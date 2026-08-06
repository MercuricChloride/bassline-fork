include pkg/prelude

import std/os
import pkg/core
import pkg/lib/crypto/digest
import pkg/lib/common
import ./util

type
  FileStore* = object
    root*: string
  FileStoreError* = object of CatchableError

proc defaultRoot*(): string =
  getHomeDir() / ".bl" / "store"

proc fileStore*(root: string = defaultRoot()): FileStore =
  FileStore(root: root)

func addressable(d: Digest): bool =
  ## Whether we can store can this particular digest
  ## 
  ## Ensures that we know the hash algo so we can verify this
  ## and that the size of the hash is correct and safe
  knownAlgo($d.algo) and d.hash.len == DigestBytes

const Fanout = 3 
## Leading chars of a name that spell its shard dir
## <abc> / <deadbeef...>
## The reason we do this is to prevent directories 
## from becoming too large. As I for one learned
## the hard way having a dir with 15M files grinds
## the os to a halt. Oops!

func pathFor*(fs: FileStore, d: Digest): string =
  let name = hexName(d.hash)
  fs.root / $d.algo / name[0 ..< Fanout] / name[Fanout .. ^1]

proc put*(fs: FileStore, v: sink Value): Digest =
  let
    d = digest v
    path = fs.pathFor(d)
  if not fileExists(path):
    createDir(path.parentDir)
    let tmp = path & ".tmp" & $getCurrentProcessId()
    writeFile(tmp, encode(v))
    moveFile(tmp, path)
  return d

proc has*(fs: FileStore, d: Digest): bool =
  addressable(d) and fileExists(fs.pathFor(d))

proc get*(fs: FileStore, d: Digest): Option[Value] =
  ## Tries to retrieve a value from the store
  ## If the store doesn't hold it, this returns none.
  ## If the returned value doesn't hash to the same hash
  ## we throw
  if not fs.has(d):
    return none Value
  let raw = readFile(fs.pathFor(d)).toBytes()
  if not verifies(d, raw):
    refuse "malformed value: the store's bytes for hash " & hexName(d.hash) & " don't match"
  some decode raw

iterator stored*(s: FileStore): Digest =
  for algoDir in walkDir(s.root):
    if algoDir.kind != pcDir:
      continue
    let algo = lastPathPart(algoDir.path)
    if not knownAlgo(algo):
      refuse "malformed store: unknown algo"
    for shard in walkDir(algoDir.path):
      if shard.kind != pcDir:
        continue
      let a = lastPathPart(shard.path)
      if a.len != Fanout:
        continue # not a sharded dir
      for entry in walkDir(shard.path):
        if entry.kind != pcFile:
          continue
        let name = a & lastPathPart(entry.path)
        if not isHexName(name):
          continue
        yield Digest(algo: Sym(algo), hash: unhexName(name))