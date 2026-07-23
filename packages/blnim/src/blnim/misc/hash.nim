{.experimental: "strictFuncs".}

## This module is probably poorly named! Too bad!
##
## This is table & set plumbing, not a deterministic universal hash.
## This is because the nim table hasher it isn't stable across
## nim versions or writer chunking patterns.
##
## If you need a hashed digest of a value, use codec/digest to get it's
## sha256 over the ce bytes.

import std/hashes
import ../codec/encode

export encode
export hashes

type HashWriter = object
  h: Hash

func write(w: var HashWriter, b: byte) =
  w.h = w.h !& int(b)

func write(w: var HashWriter, bytes: openArray[byte]) =
  w.h = w.h !& hashes.hash(bytes)

func hash*(v: Value): Hash =
  var w = HashWriter(h: 0)
  v.encodeInto(w)
  !$w.h
