##[
  Digests over a value's CE bytes.

    (digest ALGO HASH)

  ALGO is sha256 or blake2b, and HASH its 32 bytes: blake2b here is
  blake2b-256, nimcrypto's parameterised form, not a truncation. A
  digest is read exactly, like everything clave speaks.
]##

import nimcrypto/[blake2, sha2]
import ../../[core, mold]
export mold

refuseWith BasslineError

moldable """
  (struct digest {exact (rep record)}
    (algo (symbol {(one-of sha256 blake2b)}))
    (hash (bytes {(len 32)})))
"""

const
  Blake2bAlgo* = "blake2b"
  Sha256Algo* = "sha256"

type Hash* = array[32, byte]

func sha256*(bytes: openArray[byte]): Hash =
  var ctx: sha2.sha256
  ctx.init()
  ctx.update(bytes)
  ctx.finish().data

func blake2b*(bytes: openArray[byte]): Hash =
  var ctx: Blake2bContext[256]
  ctx.init()
  ctx.update(bytes)
  ctx.finish().data

proc hash*(ce: openArray[byte], algo: string): Hash =
  if algo == "sha256":
    sha256 ce
  elif algo == "blake2b":
    blake2b ce
  else:
    refuse "unknown hash algorithm: " & $algo

proc digest*(value: Value, algo: string): Digest =
  ## the digest of v's CE bytes
  Digest(algo: algo, hash: hash(value.ce, algo))

proc verifies*(d: Digest, ce: openArray[byte]): bool =
  ## whether d is the digest of these CE bytes
  hash(ce, d.algo) == d.hash

proc verifies*(d: Digest, v: Value): bool =
  ## whether d is the digest of v
  d.verifies(ce(v))