{.compile: "../../vendor/monocypher/monocypher.c".}
{.compile: "../../vendor/monocypher/monocypher-ed25519.c".}

type
  Seed* = array[32, byte]
  Key* = array[32, byte]
  SecretKey* = array[64, byte]
  Sig* = array[64, byte]

  EddsaHash* {.pure.} = enum
    Blake2b, Sha512

proc crypto_eddsa_key_pair(secretKey, publicKey, seed: ptr uint8) {.importc, cdecl.}
proc crypto_eddsa_sign(signature, secretKey, message: ptr uint8, size: csize_t) {.importc, cdecl.}
proc crypto_eddsa_check(signature, publicKey, message: ptr uint8, size: csize_t): cint {.importc, cdecl.}
proc crypto_eddsa_check_equation(signature, publicKey, hRam: ptr uint8): cint {.importc, cdecl.}
proc crypto_ed25519_key_pair(secretKey, publicKey, seed: ptr uint8) {.importc, cdecl.}
proc crypto_ed25519_sign(signature, secretKey, message: ptr uint8, size: csize_t) {.importc, cdecl.}
proc crypto_ed25519_check(signature, publicKey, message: ptr uint8, size: csize_t): cint {.importc, cdecl.}

template first(bytes: openArray[byte]): ptr uint8 =
  if bytes.len > 0: bytes[0].addr else: nil

func keyPair*(hash: EddsaHash, seed: var Seed): (SecretKey, Key) =
  # monocypher wipes the seed it reads, so a caller that keeps its seed
  # hands over a copy
  {.cast(noSideEffect).}:
    case hash
    of EddsaHash.Blake2b:
      crypto_eddsa_key_pair(result[0][0].addr, result[1][0].addr, seed[0].addr)
    of EddsaHash.Sha512:
      crypto_ed25519_key_pair(result[0][0].addr, result[1][0].addr, seed[0].addr)

func sign*(hash: EddsaHash, secret: SecretKey, msg: openArray[byte]): Sig =
  {.cast(noSideEffect).}:
    case hash
    of EddsaHash.Blake2b:
      crypto_eddsa_sign(result[0].addr, secret[0].addr, msg.first, csize_t(msg.len))
    of EddsaHash.Sha512:
      crypto_ed25519_sign(result[0].addr, secret[0].addr, msg.first, csize_t(msg.len))

func smallOrder*(key: Key): bool =
  # monocypher checks [8]([S]B - [h]A - R) against the identity and accepts
  # a key of small order, so anyone can sign as one. With R the identity,
  # S zero and h one, the check holds exactly when [8]A is the identity,
  # which is what small order means
  var
    trivial: Sig
    one: array[32, byte]
  trivial[0] = 1
  one[0] = 1
  {.cast(noSideEffect).}:
    crypto_eddsa_check_equation(trivial[0].addr, key[0].addr, one[0].addr) == 0

func check*(hash: EddsaHash, sig: Sig, key: Key, msg: openArray[byte]): bool =
  if key.smallOrder:
    return false
  {.cast(noSideEffect).}:
    case hash
    of EddsaHash.Blake2b:
      crypto_eddsa_check(sig[0].addr, key[0].addr, msg.first, csize_t(msg.len)) == 0
    of EddsaHash.Sha512:
      crypto_ed25519_check(sig[0].addr, key[0].addr, msg.first, csize_t(msg.len)) == 0
