import std/[strutils, unittest]
import bassline
import bassline_crypto
import bassline_crypto/eddsa

let
  v = bl"""(hello "world" [1 2 3] {a: 1})"""
  seed = block:
    var s = newString(32)
    for i in 0 ..< 32: s[i] = char(i * 7)
    s
  kp = keypairFromSeed(seed, EddsaBlake2b)
  zeroKey = keypairFromSeed(newString(32), EddsaBlake2b).pubkey

template refuses(call: untyped) =
  expect BasslineError:
    discard call

suite "agreement with legacy/blnim":
  test "keys, digests and signed values are byte for byte what blnim makes":
    check kp.pubkey == parseHexStr"bf0eda64c4c7b7911b1db004d06f0a94709bddd07545e63275864e6df7ea4704"
    check zeroKey == parseHexStr"19d3d919475deed4696b5d13018151d1af88b2bd3bcff048b45031c1f36d1858"
    check v.ce == parseHexStr"704568656c6c6f35776f726c6460213121322133a08041612131a0a0"
    check digest(v, Blake2bAlgo).hash == parseHexStr"e29e2f9e6dcea39ae724f268c6fe142769eb8a71e73ce7cb790a7afa4d1ed28b"
    check digest(v, Sha256Algo).hash == parseHexStr"77721fcb588539bed0a8c2a6f129793ca5cfd7b771c1c9662a4814ea8de3f69d"
    check digest(v, Blake2bAlgo).toNode.ce == parseHexStr"70466469676573744707626c616b6532625720e29e2f9e6dcea39ae724f268c6fe142769eb8a71e73ce7cb790a7afa4d1ed28ba0"
    check kp.toNode.ce == parseHexStr"7047076b657970616972470d65646473612d626c616b653262572000070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d95720bf0eda64c4c7b7911b1db004d06f0a94709bddd07545e63275864e6df7ea4704a0"
    check kp.signed(v).toNode.ce == parseHexStr"70467369676e6564704568656c6c6f35776f726c6460213121322133a08041612131a0a07047097369676e6174757265470d65646473612d626c616b65326257403dec05a91c18db8d8027626ee38b9326dcf8027b407fd965ff1a10722b0083d50bc0b167d0de9e24d20d7f13c7325fbf5f5845a283e70acb4d625642914054045720bf0eda64c4c7b7911b1db004d06f0a94709bddd07545e63275864e6df7ea4704a0a0"
    check kp.signed(bl"!(go here)").toNode.ce == parseHexStr"70467369676e65647842676f4468657265a07047097369676e6174757265470d65646473612d626c616b6532625740a9aee77fe56617e45f0f6dcf4974803c8dda73f65beabdd55c784c0b4b485b61a555ca0fcbfa2a35b693bd21deb88b3dc18f56c458b8e21ca00371190a481d0a5720bf0eda64c4c7b7911b1db004d06f0a94709bddd07545e63275864e6df7ea4704a0a0"

  test "what blnim signed holds here":
    var r = initReader()
    let fromBlnim = r.readOne(parseHexStr"70467369676e6564704568656c6c6f35776f726c6460213121322133a08041612131a0a07047097369676e6174757265470d65646473612d626c616b65326257403dec05a91c18db8d8027626ee38b9326dcf8027b407fd965ff1a10722b0083d50bc0b167d0de9e24d20d7f13c7325fbf5f5845a283e70acb4d625642914054045720bf0eda64c4c7b7911b1db004d06f0a94709bddd07545e63275864e6df7ea4704a0a0").toNode
    check fromBlnim.toSigned.holds
    check fromBlnim.toSigned.value == v

suite "digests":
  test "known answers over raw bytes":
    check sha256("abc".toBytes) == parseHexStr"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check blake2b("abc".toBytes) == parseHexStr"bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319"
    check sha256("".toBytes) == parseHexStr"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check keccak256("".toBytes) == parseHexStr"c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    check keccak256(parseHexStr("1f877c").toBytes) == parseHexStr"627d7bc1491b2ab127282827b8de2d276b13d7d70fb4c5957fdf20655bc7ac30"

  test "a digest verifies its value and no other":
    for algo in [Blake2bAlgo, Sha256Algo, Keccak256Algo]:
      let d = digest(v, algo)
      check d.algo == algo
      check d.verifies(v)
      let bytes = v.ce
      check d.verifies(bytes.toBytes)
      check not d.verifies(bl"""(hello "world")""")
      check not d.verifies(bl"""!(hello "world" [1 2 3] {a: 1})""")

  test "a digest round trips as a value":
    let d = digest(v, Blake2bAlgo)
    let h = Bytes(d.hash)
    check d.toNode == bl"(digest blake2b $h)"
    check d.toNode.toDigest == d

  test "an algorithm this doesn't know can't make a digest, and one it reads doesn't verify":
    refuses hash("x".toBytes, "md5")
    refuses digest(v, "md5")
    let zeros = Bytes(newString(32))
    let md5 = bl"(digest md5 $zeros)".toDigest
    check md5.algo == "md5"
    check not md5.verifies(v)
    check not bl"(digest sha256 0x00)".toDigest.verifies(v)

  test "what is not a digest is refused":
    refuses bl"""(digest sha256 "text")""".toDigest
    refuses bl"(hash sha256 0x00)".toDigest
    refuses bl"(digest sha256! 0x00)".toDigest
    let h = Bytes(digest(v, Sha256Algo).hash)
    refuses bl"(digest sha256 $h extra)".toDigest
    refuses bl"!(digest sha256 $h)".toDigest

suite "signatures":
  test "a keypair derives from its seed and is written as a value":
    check kp.scheme == EddsaBlake2b
    check kp.seed == seed
    let (s, p) = (Bytes(seed), Bytes(kp.pubkey))
    check kp.toNode == bl"(keypair eddsa-blake2b $s $p)"
    check kp.toNode.toKeypair == kp
    refuses keypairFromSeed("short")
    refuses bl"(keypair rsa $s $p)".toKeypair
    refuses bl"(keypair eddsa-blake2b 0x00 $p)".toKeypair
    refuses bl"(keypair eddsa-blake2b $s $p extra)".toKeypair
    refuses bl"!(keypair eddsa-blake2b $s $p)".toKeypair

  test "a signature holds for its value and its key alone":
    let sig = kp.sign(v)
    check sig.scheme == EddsaBlake2b
    check sig.pubkey == kp.pubkey
    check sig.holds(v)
    check not sig.holds(bl"""(hello "world")""")
    check not sig.holds(bl"""!(hello "world" [1 2 3] {a: 1})""")
    check not Signature(scheme: sig.scheme, sig: sig.sig, pubkey: zeroKey).holds(v)
    check not Signature(scheme: "rsa", sig: sig.sig, pubkey: sig.pubkey).holds(v)
    check not Signature(scheme: sig.scheme, sig: sig.sig[0 ..< 63], pubkey: sig.pubkey).holds(v)

  test "a signed value travels as one value":
    let s = kp.signed(v)
    check s.holds
    let (raw, p) = (Bytes(s.sig.sig), Bytes(kp.pubkey))
    check s.toNode == bl"(signed $v (signature eddsa-blake2b $raw $p))"
    let back = s.toNode.toSigned
    check back.toNode == s.toNode
    check back.holds
    let m = kp.signed(bl"!(go here)")
    check m.toNode.toSigned.holds

  test "a tampered signed value does not hold":
    var s = kp.signed(v)
    s.value = bl"""(hello "world" [1 2 4] {a: 1})"""
    check not s.holds
    var t = kp.signed(v)
    t.sig.sig[0] = char(byte(t.sig.sig[0]) xor 1)
    check not t.holds
    var u = kp.signed(v)
    u.sig.pubkey = zeroKey
    check not u.holds

  test "a scheme this doesn't know reads, and doesn't hold":
    let (one, p) = (Bytes(kp.sign(bl"1").sig), Bytes(kp.pubkey))
    let rsa = bl"(signed 1 (signature rsa $one $p))".toSigned
    check rsa.sig.scheme == "rsa"
    check not rsa.holds
    check not bl"(signed 1 (signature eddsa-blake2b 0x00 $p))".toSigned.holds

  test "what is not a signed value is refused":
    let s = kp.signed(v)
    let (sig, raw, p) = (s.sig.toNode, Bytes(s.sig.sig), Bytes(kp.pubkey))
    refuses bl"(signed 1 5)".toSigned
    refuses bl"(signed $v $sig extra)".toSigned
    refuses bl"(signed $v (signature eddsa-blake2b $raw $p extra))".toSigned
    refuses bl"""(signed $v (signature eddsa-blake2b "sig" $p))""".toSigned
    refuses bl"!(signed $v $sig)".toSigned
    refuses bl"(signed $v !(signature eddsa-blake2b $raw $p))".toSigned

  test "a key of small order holds for nothing":
    let trivial = Bytes("\x01" & newString(63))
    for hex in ["0100000000000000000000000000000000000000000000000000000000000000",
                "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
                "0000000000000000000000000000000000000000000000000000000000000000",
                "0000000000000000000000000000000000000000000000000000000000000080"]:
      let key = Bytes(parseHexStr(hex))
      for said in [v, bl"anything", bl"[]"]:
        check not bl"(signed $said (signature eddsa-blake2b $trivial $key))".toSigned.holds
    check kp.sign(v).holds(v)

suite "ed25519":
  test "known answers from monocypher's own vectors":
    for (seed, key, msg, sig) in [
        ("e4e4c4054fe35a75d9c0f679ad8770d8227e68e4c1e68ce67ee88e6be251a207",
         "53bbbdb18a3aba5405f4d61f2535bfd9f4b448280f975f7f31968025ddeff96f", "",
         "fd6abddb65c6bb74c1bd9ead2a58517546cbcfcd69abaa1b60873ceee62793a2a069ccd9b1b320d318a1bc9a80de2c8b228245e5993b975c438a6adaf3ed3e05"),
        ("d19cfb8cb3940aba546f0be57895e2cc869fe55aab069c5abcf9e7ba6444a846",
         "c9ead10ab1223df9b779f6dc3cc36917364cbfe5f31c89646118dbc966bb9b88", "e5",
         "2eece7bbafe10648b8b914c62a67d5c014766f646840a73794e39389031f2f0bb4ef7b23495185855435891c3bf57be5e9a3f2a57205e32c5545aa1d4b26ed08")]:
      var s: Seed
      s[0 .. ^1] = parseHexStr(seed).toBytes
      let (secret, public) = EddsaHash.Sha512.keyPair(s)
      check public.toString == parseHexStr(key)
      let message = parseHexStr(msg)
      let made = EddsaHash.Sha512.sign(secret, message.toBytes)
      check made.toString == parseHexStr(sig)
      check EddsaHash.Sha512.check(made, public, message.toBytes)
      check not EddsaHash.Blake2b.check(made, public, message.toBytes)

  test "a value signed with ed25519 holds, and only under ed25519":
    let ed = keypairFromSeed(seed, Ed25519)
    check ed.scheme == Ed25519
    check ed.pubkey != kp.pubkey
    let s = ed.signed(v)
    check s.holds
    let (raw, p) = (Bytes(s.sig.sig), Bytes(ed.pubkey))
    check s.toNode == bl"(signed $v (signature ed25519 $raw $p))"
    check s.toNode.toSigned.holds
    var relabelled = s
    relabelled.sig.scheme = EddsaBlake2b
    check not relabelled.holds
    check ed.toNode.toKeypair == ed

  test "a key of small order holds for nothing under ed25519 either":
    let trivial = Bytes("\x01" & newString(63))
    let identity = Bytes("\x01" & newString(31))
    check not bl"(signed $v (signature ed25519 $trivial $identity))".toSigned.holds

suite "keys":
  test "a public key is spoken with its scheme":
    let p = Bytes(kp.pubkey)
    check kp.publicKey.toNode == bl"(key eddsa-blake2b $p)"
    check kp.publicKey.toNode.toPublicKey == kp.publicKey
    check kp.sign(v).publicKey == kp.publicKey
    check keypairFromSeed(seed, Ed25519).publicKey.scheme == Ed25519
    refuses bl"""(key eddsa-blake2b "text")""".toPublicKey
    refuses bl"(key eddsa-blake2b $p extra)".toPublicKey
    refuses bl"!(key eddsa-blake2b $p)".toPublicKey
    check bl"(key rsa 0x00)".toPublicKey.scheme == "rsa"

  test "a new keypair is fresh each time and signs in its scheme":
    for scheme in [EddsaBlake2b, Ed25519]:
      let (a, b) = (newKeypair(scheme), newKeypair(scheme))
      check a.scheme == scheme
      check a.seed.len == 32
      check a.seed != b.seed
      check a.pubkey != b.pubkey
      check a.signed(v).holds
      check keypairFromSeed(a.seed, scheme) == a
    check newKeypair().scheme == Ed25519
    check keypairFromSeed(seed).scheme == Ed25519
    refuses newKeypair("rsa")

suite "checked values":
  let
    said = kp.signed(v)
    plain = said.toNode

  test "a signed value that holds is checked, and reifies to what was said":
    let c = plain.checked
    check not c.isNil
    check c.value == v and c.key == kp.publicKey and c.signature == said.sig
    check c.reified == plain.asValue
    check c.toNode.checked == c
    check c.toNode != plain and c.toNode.reified == plain

  test "what isn't a signed value, or doesn't hold, isn't checked":
    var tampered = plain
    tampered.asValue[1] = bl"changed"
    check tampered.checked.isNil
    check v.checked.isNil
    check bl"(signed)".checked.isNil
    check said.sig.toNode.checked.isNil

  test "a signed track keeps only signed values that hold":
    var tampered = plain
    tampered.asValue[1] = bl"changed"
    let t = SignedTrack()
    check t.add(plain) == Contribution.Kept
    check t.add(plain.checked.toNode) == Contribution.Kept
    check t.add(newKeypair().signed(bl"(q a)").toNode) == Contribution.Kept
    check t.add(v) == Contribution.Ignored
    check t.add(tampered) == Contribution.Ignored
    check t.len == 3

  test "a checker offers what holds on its track, as checked values, to a track of its own":
    var tampered = plain
    tampered.asValue[1] = bl"changed"
    let
      heard = Track()
      kept = Track()
    discard heard.add(plain)
    discard heard.add(v)
    heard.up Checker(into: kept)
    check kept.len == 1
    discard heard.add(tampered)
    let other = newKeypair().signed(bl"(q a)").toNode
    discard heard.add(other)
    check kept.len == 2
    heard.reviseIt:
      it[1] = plain
    check kept.len == 3
    var
      reads: seq[Node]
      printed: seq[string]
    for i in 0 ..< kept.len:
      case kept[i]
      of Present(n):
        check n.isBound and not n.checked.isNil
        reads.add n.reified
        printed.add $n
      of Absent:
        discard
    check reads == @[plain, other, plain]
    check printed[0] == $plain

  test "a signed value with live parts is checked by what it stands for":
    let inner = kp.signed(bl"(q a)")
    var n = kp.signed(inner.toNode).toNode
    n.asValue[1] = inner.toNode.checked.toNode
    check n.isPlain and not n.isPure
    check not n.checked.isNil

  test "a checker doesn't offer again a slot made live in place":
    let
      heard = Track()
      kept = Track()
    discard heard.add(plain)
    heard.up Checker(into: kept)
    heard.reviseIt:
      it[0] = plain.checked.toNode
    check kept.len == 1
    heard.reviseIt:
      it[0] = kp.signed(bl"(q other)").toNode
    check kept.len == 2
