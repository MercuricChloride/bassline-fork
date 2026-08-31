## The EdDSA (curve25519, blake2b) that signs for clave.
## This is probably gonna get thrown out in favor of a
## more traditional signature algorithm. But it's
## good-enuf
{.compile: "../../../vendor/monocypher/monocypher.c".}

when defined(useFuthark):
  import std/os
  import futhark

  importc:
    path currentSourcePath().parentDir.parentDir.parentDir.parentDir / "vendor" /
      "monocypher"
    outputPath currentSourcePath().parentDir / "monocypher_gen.nim"
    "monocypher.h"
else:
  include ./monocypher_gen

type
  Seed* = array[32, byte]
  Key* = array[32, byte]
  SecretKey* = array[64, byte]
  Sig* = array[64, byte]

func keyPair*(seed: var Seed): (SecretKey, Key) =
  ## Derives a signing pair. Monocypher wipes the seed it reads, so
  ## hand it a copy unless you mean to lose yours.
  {.cast(noSideEffect).}:
    crypto_eddsa_key_pair(result[0], result[1], seed)

func sign*(secret: SecretKey, msg: openArray[byte]): Sig =
  let p = if msg.len > 0: addr msg[0] else: nil
  {.cast(noSideEffect).}:
    crypto_eddsa_sign(result, secret, p, csize_t(msg.len))

func check*(sig: Sig, public: Key, msg: openArray[byte]): bool =
  let p = if msg.len > 0: addr msg[0] else: nil
  {.cast(noSideEffect).}:
    crypto_eddsa_check(sig, public, p, csize_t(msg.len)) == 0
