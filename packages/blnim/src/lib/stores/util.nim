include pkg/prelude
import std/strutils
import pkg/core
import pkg/lib/[common, print]
import pkg/lib/crypto/digest

export strutils, core, digest, common, print

const DigestBytes* = 32 # blake2b-256 and sha256 alike

func hexName*(hash: openArray[byte]): string =
  result = newStringOfCap(hash.len * 2)
  for b in hash:
    result.add toHex(b).toLowerAscii()

func unhexName*(name: string): seq[byte] =
  parseHexStr(name).toBytes()

func isHexName*(name: string): bool =
  ## exactly the shape hexName gives a digest: 64 lowercase hex digits.
  ## Anything else in a store directory is not an entry.
  if name.len != DigestBytes * 2:
    return false
  for c in name:
    if c notin {'0' .. '9', 'a' .. 'f'}:
      return false
  true