## bl clave: keygen, sign and verify

import cli

suite "clave":
  let key = tmp / "keys" / "key.blb"
  let values = blb("\"hello\" (a b!) 42! !(go 1) {k: nil!}")

  test "keygen keeps a keypair owner-only and won't overwrite it":
    let r = sh("bl clave keygen --out " & key)
    check r.code == 0
    check "-- public 0x" in r.errors
    check getFilePermissions(key) == {fpUserRead, fpUserWrite}
    check decoded(readFile(key))[0].head == sym("keypair")
    let again = sh("bl clave keygen --out " & key)
    check again.code == 1
    check "exists" in again.errors
    check sh("bl clave keygen --force --out " & key).code == 0

  test "sign then verify passes every value on, signature and all":
    let signed = sh("bl clave sign --key " & key, values)
    check signed.code == 0
    check signed.output.decoded.len == 5
    check signed.output.decoded[1].items[1] == decoded(blb("(a b!)"))[0]
    let verified = sh("bl clave verify", signed.output)
    check verified.code == 0
    check verified.output == signed.output

  test "a tampered byte fails verify, with the reason":
    var signed = sh("bl clave sign --key " & key, values).output
    signed[signed.find("hello")] = 'j'
    let r = sh("bl clave verify", signed)
    check r.code == 1
    check r.output == ""
    check "signature does not hold" in r.errors
    check sh("bl clave verify", blb("(not signed)")).code == 1

  test "--drop drops what doesn't hold and counts it":
    let good = sh("bl clave sign --key " & key, blb("good")).output
    var bad = sh("bl clave sign --key " & key, blb("\"hello\"")).output
    bad[bad.find("hello")] = 'j'
    let r = sh("bl clave verify --drop", good & bad & blb("(unsigned)"))
    check r.code == 0
    check r.output == good
    check "dropped value 2 (1 so far)" in r.errors
    check "dropped value 3 (2 so far)" in r.errors
    check "-- held 1, dropped 2" in r.errors

  test "nothing may ride along inside the signature either":
    let signed = sh("bl clave sign --key " & key, blb("(pay bob 5)")).output
    var v = decoded(signed)[0]
    v.items[2].items.add sym("vouched-by-bank")
    let r = sh("bl clave verify", v.ce.toString)
    check r.code == 1
    check "not (signature …) with exactly 3 items" in r.errors
    check sh("bl clave verify --drop", v.ce.toString).output == ""

  test "sign without a key says how to make one":
    let r = sh("bl clave sign --key " & tmp / "nokey.blb", values)
    check r.code == 1
    check "bl clave keygen" in r.errors
