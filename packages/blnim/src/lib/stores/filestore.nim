import std/os
import ./util

type
  FileStore* = object
    root*: string

proc defaultRoot*(): string =
  getHomeDir() / ".bl" / "store"

proc fileStore*(root: string = defaultRoot()): FileStore =
  createDir(root)
  FileStore(root: root)

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
  fileExists fs.pathFor(d)

proc get*(fs: FileStore, d: Digest): Option[Value] =
  if fs.has(d):
    some decode readFile(fs.pathFor(d)).toBytes()
  else:
    none Value

iterator stored*(s: FileStore): Digest =
  for algoDir in walkDir(s.root):
    if algoDir.kind != pcDir:
      continue
    let algo = lastPathPart(algoDir.path)
    for entry in walkDir(algoDir.path):
      if entry.kind != pcFile:
        continue
      let hash = unhexName(entry.path.lastPathPart)
      yield Digest(algo: Sym(algo), hash: hash)