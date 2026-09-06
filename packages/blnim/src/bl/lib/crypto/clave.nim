##[
  clave: keypairs, signatures, and signed values.

    (keypair scheme! seed! public!)
    (signature scheme! sig! pubkey!)
    (signed value! signature!)

  A signature covers a value's CE bytes, so what is attested is the
  value itself. The one scheme is monocypher's EdDSA over curve25519
  with blake2b, spoken as `eddsa-blake2b`; the library describes it
  and the lengths it fixes, so the derived types are its arrays.

  A keypair is a value so it can be kept; the secret key is derived
  from the seed when it is needed and never spoken.
]##

import ../../core
import ../blmacro
import ./[eddsa, types]
export types

proc keypairFromSeed*(seed: Seed): Keypair =
  ## the pair a seed derives
  # monocypher wipes the seed it derives from, and Nim passes arrays
  # by hidden pointer, so it is handed a copy
  var scratch = seed
  let (_, pubkey) = keyPair(scratch)
  Keypair(scheme: Scheme, seed: seed, pubkey: pubkey)

proc secret(kp: Keypair): SecretKey =
  var scratch = kp.seed
  keyPair(scratch)[0]

proc sign*(kp: Keypair, v: Value): Signature =
  ## kp's signature of v's CE bytes
  Signature(scheme: Scheme, sig: eddsa.sign(kp.secret, ce(v)), pubkey: kp.pubkey)

proc signed*(kp: Keypair, v: Value): Signed =
  ## v alongside kp's signature of it
  Signed(value: v, sig: kp.sign(v))

proc holds*(s: Signature, v: Value): bool =
  ## whether s is a signature of v under its scheme by its key
  s.scheme == Scheme and check(s.sig, s.pubkey, ce(v))

proc holds*(s: Signed): bool =
  ## whether the signature is of the value it travels with
  s.sig.holds(s.value)