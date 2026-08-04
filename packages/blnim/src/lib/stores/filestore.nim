include pkg/prelude

import std/os
import pkg/lib/crypto/digest
import ./util

type
  FileStore* = object
    root*: string

proc defaultRoot*(): string =
  getHomeDir() / ".bl" / "store"

proc fileStore*(root: string = defaultRoot()): FileStore =
  createDir(root)
  FileStore(root: root)

func addressable(d: Digest): bool =
  ## whether this store can honor the name at all: an algo `verifies`
  ## speaks and a hash of its size. A digest that fails this is not an
  ## address here -- in particular it never becomes a filesystem path,
  ## so a hostile algo like `../..` has nowhere to point.
  knownAlgo($d.algo) and d.hash.len == DigestBytes

proc pathFor(fs: FileStore, d: Digest): string =
  fs.root / $d.algo / hexName(d.hash)

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
  ## The value the name stands for, or none when the store doesn't
  ## hold it. The bytes on disk are verified against the name before
  ## being vouched for: content that doesn't check is an integrity
  ## failure and refuses loudly, not a miss.
  if not fs.has(d):
    return none Value
  let raw = readFile(fs.pathFor(d)).toBytes()
  if not verifies(d, raw):
    raise newException(
      ValueError, "the store's bytes for " & hexName(d.hash) & " don't verify"
    )
  some decode raw

iterator stored*(s: FileStore): Digest =
  for algoDir in walkDir(s.root):
    if algoDir.kind != pcDir:
      continue
    let algo = lastPathPart(algoDir.path)
    if not knownAlgo(algo):
      continue
    for entry in walkDir(algoDir.path):
      if entry.kind != pcFile:
        continue
      let name = entry.path.lastPathPart
      if not isHexName(name):
        continue # tmp leftovers and other squatters are not entries
      yield Digest(algo: Sym(algo), hash: unhexName(name))