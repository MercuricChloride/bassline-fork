## The content-addressed store behind bl put / bl get.
##
## Semantically the store IS one dict value, {digest: content, ...};
## this file-per-value tree is just its local, disposable layout
## Files hold the content value's CE bytes, named sha256/<hex>, 
## so a file's name doubles as its integrity check: sha256(file bytes) 
## must equal it.
## 
## This is probably going to be changed later to something more robust
## and "proper"

import std/[os, options, strutils]
import ../blnim/codec/[decode, digest, encode]
import ../blnim/misc/common
import util
export options, decode, digest, encode, common

type
  Store* = object
    root*: string

  StoreError* = object of CatchableError

proc defaultStoreRoot*(): string =
  blHome() / "store"

proc openStore*(root: string): Store =
  createDir(root)
  Store(root: root)

func hexName(hash: openArray[byte]): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(hash.len * 2)
  for b in hash:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 0xF)]

func safeAlgo*(algo: string): bool =
  ## Algo names come off the wire and become path segments; only a
  ## tame alphabet may pass.
  algo.len > 0 and allCharsInSet(algo, {'a' .. 'z', '0' .. '9', '-'})

proc pathFor(s: Store, algo: string, hash: openArray[byte]): string =
  s.root / algo / hexName(hash)

proc put*[T: ValueLike](s: Store, x: T): Digest =
  ## Holds x as a value, returns its name: idempotent, convergent --
  ## the same value from anyone lands as the same file.
  let v = toValue(x)
  let d = digest(v)
  let dest = s.pathFor("sha256", d.hash)
  if not fileExists(dest):
    createDir(dest.parentDir)
    let tmp = dest & ".tmp" & $getCurrentProcessId()
    writeFile(tmp, encodeToString(v))
    moveFile(tmp, dest)
  d

proc load*(s: Store, algo: string, hash: seq[byte]): Option[string] =
  ## The stored CE bytes for a name, or none if the store doesn't
  ## hold it. Raises StoreError if the file no longer matches its
  ## name -- a store that lies is worse than one that's missing.
  if not safeAlgo(algo):
    raise newException(StoreError, "unspeakable algo name: " & algo)
  let path = s.pathFor(algo, hash)
  if not fileExists(path):
    return none string
  let raw = readFile(path)
  if algo == "sha256":
    if @(sha256(raw.toOpenArrayByte(0, raw.high))) != hash:
      raise newException(StoreError, "corrupt: " & path & " no longer matches its name")
  some raw

proc load*(s: Store, d: Digest): Option[string] =
  ## The stored CE bytes for a typed name. The Sym -> path-string
  ## cast lives here, at the boundary, and nowhere else.
  s.load($d.algo, d.hash)
