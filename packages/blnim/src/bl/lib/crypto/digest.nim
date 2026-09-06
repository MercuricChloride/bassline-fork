##[
  Digests over a value's CE bytes.

    (digest algo! bytes!)

  The library describes `digest` with `algo!` a `HashAlgo`, one of
  sha256 and blake2b, and `bytes!` 32 bytes: blake2b here is
  blake2b-256, nimcrypto's parameterised form, not a truncation.
]##

import nimcrypto/[blake2, sha2]
import ../../core
import ../[blmacro, ops]

template refuse(msg: string) =
  raise newException(ValueError, msg)

let
  Blake2bAlgo* = bl blake2b
  Sha256Algo* = bl sha256

type 
  Hash* = array[32, byte]
  Digest* = object
    algo*: Value
    hash*: Hash

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

proc hash*(ce: openArray[byte], algo: Value): Hash =
  if algo == Sha256Algo:
    sha256 ce
  elif algo == Blake2bAlgo:
    blake2b ce
  else:
    refuse "unknown hash algorithm: " & $algo

proc digest*(value, algo: Value): Digest =
  ## the digest of v's CE bytes
  Digest(algo: algo, hash: hash(value.ce, algo))

proc verifies*(d: Digest, ce: openArray[byte]): bool =
  ## whether d is the digest of these CE bytes
  hash(ce, d.algo) == d.hash

proc verifies*(d: Digest, v: Value): bool =
  ## whether d is the digest of v
  d.verifies(ce(v))

func shape*(_: typedesc[Digest]): Value =
  bl digest(!algo, !hash)

proc fromValue*(T: typedesc[Digest], v: Value): Digest =
  var bindings: Value
  guard T.shape.extract(v, bindings), "invalid digest shape"
  let
    algo = bindings[bl algo]
    hash = bindings[bl hash]
  guard algo.kind == bSym, "digest algo must be a symbol"
  guard hash.kind == bBytes, "digest hash must bytes"
  guard algo == Sha256Algo or algo == Blake2bAlgo, "unknown hash algo"
  guard hash.bytes.len == 32, "invalid hash length"

  result.algo = algo
  copyMem addr result[0], addr hash.bytes[0], 32

proc toValue*(self: Digest): Value =
  bl digest(%(self.algo), %(self.hash))