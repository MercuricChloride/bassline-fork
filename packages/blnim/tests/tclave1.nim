import std/unittest
import std/sequtils
import blnim/misc/clave
import blnim/misc/common

let
  seed: Seed = block:
    var s: Seed
    for i in 0 ..< 32:
      s[i] = byte(i * 7)
    s
  kp = keypairFromSeed(seed)
  doc = common.file("hello", dict(@[(sym"name", text"hello.txt")]))

suite "clave":
  test "sign / verify round trip":
    let wrapped = signedValue(kp, doc)
    check isSigned(wrapped)
    check verifySigned(wrapped) == some doc

  test "signatures are deterministic":
    check sign(kp, doc) == sign(kp, doc)

  test "a different value does not verify against the same signature":
    let wrapped = signedValue(kp, doc)
    let forged = signed(text"other", wrapped.items[2])
    check isSigned(forged)
    check verifySigned(forged).isNone

  test "a tampered signature does not verify":
    var sig = @(sign(kp, doc))
    sig[10] = sig[10] xor 1
    let tampered = signed(doc, signature(Scheme, sig, kp.public))
    check isSigned(tampered)
    check verifySigned(tampered).isNone

  test "a different key does not verify":
    var otherSeed: Seed
    for i in 0 ..< 32:
      otherSeed[i] = byte(200 - i)
    let other = keypairFromSeed(otherSeed)
    let tampered = signed(doc, signature(Scheme, sign(kp, doc), other.public))
    check verifySigned(tampered).isNone

  test "keypair value round trips through recognition":
    let stored = keypair(Scheme, kp.seed, kp.public)
    let back = toKeypair(stored)
    check back.isSome
    check back.get.public == kp.public
    check sign(back.get, doc) == sign(kp, doc)

  test "unsigned and near-miss shapes are not signed":
    check not isSigned(doc)
    check not isSigned(record(sym"signed", doc))
    check not isSigned(signed(doc, record(sym"signature", sym"other",
                                          bytes(newSeqWith(64, byte 0)),
                                          bytes(newSeqWith(32, byte 0)))))
