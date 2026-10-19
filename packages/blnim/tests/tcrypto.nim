## digests and signatures over a value's CE bytes

import std/unittest
import bl/core
import bl/lib/blah
import bl/lib/crypto/[digest, clave]

let
  v = bl"""(hello "world" [1 2 3] {a: 1})"""
  seed = block:
    var s: Seed
    for i in 0 ..< 32: s[i] = byte(i * 7)
    s
  kp = keypairFromSeed(seed)
  pubkey = kp.pubkey

template refuses(call: untyped) =
  ## the door raises rather than returning a wrong reading
  expect ValueError:
    discard call

suite "digest":
  test "known answers over raw bytes":
    check @(sha256("abc".toBytes)) ==
      bl"0xba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad".bytes
    check @(blake2b("abc".toBytes)) ==
      bl"0xbddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319".bytes
    check @(sha256(newSeq[byte]())) ==
      bl"0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".bytes

  test "a digest verifies its value and no other":
    for algo in [Blake2bAlgo, Sha256Algo]:
      let d = digest(v, algo)
      check d.algo == algo
      check d.verifies(v)
      check d.verifies(ce(v))
      check not d.verifies(bl"""(hello "world")""")
      check not d.verifies(randValue(3))

  test "a digest round trips as a value":
    let d = digest(v, Blake2bAlgo)
    let dv = toValue(d)
    let h = d.hash
    check dv == bl"(digest blake2b $h)"
    check Digest.fromValue(dv).toValue == dv

  test "an unknown algorithm is refused":
    refuses hash(ce(v), "md5")
    refuses digest(v, "md5")

  test "what is not a digest of a known kind is refused":
    let zeros = newSeq[byte](32)
    refuses Digest.fromValue(bl"(digest md5 $zeros)")
    refuses Digest.fromValue(bl"(digest sha256 0x00)")      # not 32 bytes
    refuses Digest.fromValue(bl"""(digest sha256 "text")""") # not bytes
    refuses Digest.fromValue(bl"(hash sha256 0x00)")        # not the digest head
    let h = toValue(digest(v, Sha256Algo)).items[2]
    refuses Digest.fromValue(bl"(digest sha256 $h extra)")  # a field more
    refuses Digest.fromValue(bl"!(digest sha256 $h)")       # marked

suite "clave":
  test "a keypair derives from its seed and is a value":
    check kp.scheme == Scheme
    check kp.seed == seed
    check keypairFromSeed(seed).pubkey == kp.pubkey
    let kv = toValue(kp)
    check kv == bl"(keypair eddsa-blake2b $seed $pubkey)"
    check Keypair.fromValue(kv).toValue == kv
    refuses Keypair.fromValue(bl"(keypair rsa $seed $pubkey)")
    refuses Keypair.fromValue(bl"(keypair eddsa-blake2b 0x00 $pubkey)")

  test "a signature holds for its value and its key alone":
    let sig = kp.sign(v)
    check sig.scheme == Scheme
    check sig.pubkey == kp.pubkey
    check sig.holds(v)
    check not sig.holds(bl"""(hello "world")""")
    check not sig.holds(randValue(3))
    let wrongKey = Signature(scheme: sig.scheme, sig: sig.sig,
                             pubkey: keypairFromSeed(default(Seed)).pubkey)
    check not wrongKey.holds(v)
    let wrongScheme = Signature(scheme: "rsa", sig: sig.sig, pubkey: sig.pubkey)
    check not wrongScheme.holds(v)

  test "a signed value travels as one value":
    let s = kp.signed(v)
    check s.holds
    let sv = toValue(s)
    let raw = s.sig.sig
    check sv == bl"(signed $v (signature eddsa-blake2b $raw $pubkey))"
    let back = Signed.fromValue(sv)
    check back.toValue == sv
    check back.holds
    let m = kp.signed(bl"!(go here)")
    check Signed.fromValue(m.toValue).toValue == m.toValue  # any value, marked too

  test "a tampered signed value does not hold":
    var s = kp.signed(v)
    s.value = bl"""(hello "world" [1 2 4] {a: 1})"""
    check not s.holds
    var t = kp.signed(v)
    t.sig.sig[0] = t.sig.sig[0] xor 1
    check not t.holds
    var u = kp.signed(v)
    u.sig.pubkey = keypairFromSeed(default(Seed)).pubkey
    check not u.holds

  test "what is not a signature of a known kind is refused":
    refuses Signed.fromValue(bl"(signed 1 (signature eddsa-blake2b 0x00 $pubkey))") # sig not 64 bytes
    let one = kp.sign(bl"1").sig
    refuses Signed.fromValue(bl"(signed 1 (signature rsa $one $pubkey))")  # unknown scheme
    refuses Signed.fromValue(bl"(signed 1 5)")                         # sig not a record
    let s = kp.signed(v)
    let (sig, raw) = (s.sig, s.sig.sig)
    refuses Signed.fromValue(bl"(signed $v $sig extra)")               # unsigned field
    refuses Signed.fromValue(bl"(signed $v (signature eddsa-blake2b $raw $pubkey extra))") # in the signature too
    refuses Signed.fromValue(bl"!(signed $v $sig)")                    # marked
    refuses Keypair.fromValue(bl"(keypair eddsa-blake2b $seed $pubkey extra)")
