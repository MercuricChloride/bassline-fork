## bl hash: each value to the digest of its CE bytes

import std/sugar
import harness
import bl/lib/crypto/digest

proc run(t: Tool, a: Args) =
  if a.positional.len > 0:
    t.misuse "takes no arguments"
  let algo = a.get("algo", "sha256")
  if algo != Sha256Algo and algo != Blake2bAlgo:
    t.misuse "--algo is blake2b or sha256, not " & a.get("algo")
  lift((v: Value) => just digest(v, algo).toValue)

let tool* = Tool(
  name: "hash",
  summary: "each value to (digest ALGO 0x…), over its CE bytes",
  about: """
blake2b is blake2b-256. The digest is a value with a reading: whoever
holds a value whose CE hashes to it can say so.""",
  opts: @[Opt(long: "algo", arg: "ALGO",
              help: "sha256 (the default) or blake2b")],
  run: run)
