import std/strutils
import pkg/core
import pkg/lib/[digest, common, print]

export strutils, core, digest, common, print

proc hexName*(hash: openArray[byte]): string =
  result = newStringOfCap(hash.len * 2)
  for b in hash:
    result.add toHex(b).toLowerAscii()

proc unhexName*(name: string): seq[byte] =
  parseHexStr(name).toBytes()