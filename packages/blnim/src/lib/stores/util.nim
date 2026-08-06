include pkg/prelude
import std/strutils
import pkg/core

const DigestBytes* = 32
## currently all of our hashes are 32 byte
## So this is that size

func hexName*(hash: openArray[byte]): string =
  result = newStringOfCap(hash.len * 2)
  for b in hash:
    result.add toHex(b).toLowerAscii()

func unhexName*(name: string): seq[byte] =
  parseHexStr(name).toBytes()

func isHexName*(name: string): bool =
  ## whether the string matches
  ## our definition of a hex digest.
  ## 64 lowercase hex digits
  if name.len != DigestBytes * 2:
    return false
  for c in name:
    if c notin {'0' .. '9', 'a' .. 'f'}:
      return false
  true