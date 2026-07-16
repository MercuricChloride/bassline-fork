{.experimental: "strictFuncs".}

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