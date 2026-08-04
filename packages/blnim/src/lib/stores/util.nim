include pkg/prelude
import std/strutils
import pkg/core
import pkg/lib/[digest, common, print]

export strutils, core, digest, common, print

func hexName*(hash: openArray[byte]): string =
  result = newStringOfCap(hash.len * 2)
  for b in hash:
    result.add toHex(b).toLowerAscii()

func unhexName*(name: string): seq[byte] =
  parseHexStr(name).toBytes()