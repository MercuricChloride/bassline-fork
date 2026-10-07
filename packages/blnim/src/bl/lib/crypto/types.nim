##[
  The values clave speaks:

    (keypair eddsa-blake2b SEED PUBKEY)
    (signature eddsa-blake2b SIG PUBKEY)
    (signed VALUE SIGNATURE)

  Each is read exactly: a field more would ride along unread, and
  unsigned where a signature covers the value. The one scheme is
  monocypher's EdDSA over curve25519 with blake2b, and the lengths are
  the ones it fixes.
]##

import ../../[core, mold]
export mold

moldable """{
  (keypair Keypair
    [(scheme (one-of eddsa-blake2b)) (seed (bytes 32)) (pubkey (bytes 32))]
    exact)
  (signature Signature
    [(scheme (one-of eddsa-blake2b)) (sig (bytes 64)) (pubkey (bytes 32))]
    exact)
  (signed Signed [(value any) (sig Signature)] exact)
}"""

const Scheme* = "eddsa-blake2b"

type
  Seed* = array[32, byte]
  Key* = array[32, byte]
  SecretKey* = array[64, byte]
  Sig* = array[64, byte]
