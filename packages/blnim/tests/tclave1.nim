import std/[unittest, sequtils, options]

import pkg/core
import pkg/lib/obmcommon
import pkg/lib/crypto/clave

let
  seed: Seed = block:
    var s: Seed
    for i in 0 ..< 32:
      s[i] = byte(i * 7)
    s
  kp = keypairFromSeed(seed)
  doc = toValue(
    BlFile(contents: toBytes"hello", info: some BlFileInfo(name: some "hello.txt"))
  )

suite "clave":
  test "sign / verify round trip":
    let wrapped = signedValue(kp, doc)
    let s = fromValue(wrapped, Signed)
    check s.isSome
    check s.get.holds
    check s.get.value == doc

  test "signatures are deterministic":
    check sign(kp, doc) == sign(kp, doc)

  test "a different value does not verify against the same signature":
    let wrapped = signedValue(kp, doc)
    let forged = record(sym"signed", text"other", wrapped.contents[2])
    let s = fromValue(forged, Signed)
    check s.isSome # the shape is fine
    check not s.get.holds # the attestation is not

  test "a tampered signature does not verify":
    var sig = @(sign(kp, doc))
    sig[10] = sig[10] xor 1
    let tampered = record(
      sym"signed",
      doc,
      record(sym"signature", sym(Scheme), bytes(sig), bytes(@(kp.public))),
    )
    let s = fromValue(tampered, Signed)
    check s.isSome
    check not s.get.holds

  test "a different key does not verify":
    var otherSeed: Seed
    for i in 0 ..< 32:
      otherSeed[i] = byte(200 - i)
    let other = keypairFromSeed(otherSeed)
    let tampered = record(
      sym"signed",
      doc,
      record(
        sym"signature", sym(Scheme), bytes(@(sign(kp, doc))), bytes(@(other.public))
      ),
    )
    check not fromValue(tampered, Signed).get.holds

  test "keypair value round trips through recognition":
    let stored = toValue(kp)
    let back = fromValue(stored, Keypair)
    check back.isSome
    check back.get.public == kp.public
    check sign(back.get, doc) == sign(kp, doc)

  test "unsigned and near-miss shapes do not match Signed":
    check Signed.match(doc).isNone
    check Signed.match(record(sym"signed", doc)).isNone
    check Signed.match(
      record(
        sym"signed",
        doc,
        record(
          sym"signature",
          sym"other",
          bytes(newSeqWith(64, byte 0)),
          bytes(newSeqWith(32, byte 0)),
        ),
      )
    ).isNone
