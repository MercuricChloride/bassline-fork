# Crypto

Digests and signatures over values. A value's identity is its CE bytes, so anything that can be computed over bytes can be computed over a value and checked by anyone who holds the value. This dialect is how identity is spoken in bassline: a signed value says who said it, and it says so wherever it is carried, however many hands it passes through.

## What is spoken

```
(digest ALGO HASH)               the bytes ALGO makes of a value's CE
(signed VALUE SIGNATURE)         VALUE, signed
(signature SCHEME SIG KEY)       SIG, made by SCHEME over VALUE's CE, checked with KEY
(key SCHEME KEY)                 a public key, spoken on its own
```

A **digest** names a value without carrying it. A reader holding a value can check that it is the one a digest names. `ALGO` is a symbol naming the algorithm, such as `blake2b` (BLAKE2b-256), `sha256` or `keccak256`, and `HASH` is bytes.

A **signed value** carries a value and a signature over the value's CE. A signature holds exactly when `SIG` checks against the CE of `VALUE` under `KEY` by `SCHEME`. That is the whole of what checking it establishes. `SCHEME` is a symbol naming how the signature was made, such as `ed25519` or `eddsa-blake2b`, and `SIG` and `KEY` are bytes.

A **key** spoken on its own carries its scheme, since the same bytes are a different identity under another scheme. That is how a value names someone without a signature of theirs in hand.

Many schemes and algorithms can be spoken side by side, since each value names its own. A reader checks the ones it knows. A scheme it doesn't know is one it can't check, so to that reader the value is unsigned, and the value inside can still be read.

## Identity

A key is a durable identity. A reader that has seen a key before knows the same holder spoke again, and nothing else needs to be agreed for that. What a key is called, by whom, and what it may do are readings a reader makes over the signed values it holds. A signed value stays checkable when it is relayed, kept or handed on, so identity travels with what was said.

How a key is held is the holder's own business. A keypair is never spoken.

## On each axis

- **Readings.** Checking a signed value, and reading it as said by its key. Checking that a value is the one a digest names.
- **Kinds of live object.** A checked signed value, holding what was said and the key that said it, which `reified` writes back as the signed value it came from.
- **Kinds of track.** A track whose `keeps` admits only signed values that check. A jam is one: what is spoken on a jam is signed.
- **Monitors.** A monitor that checks what a track admits and offers what holds, as checked values, to a track of its own.

## Implementations

- [`nim`](nim) is the package `bassline_crypto` over `core/nim`: `import bassline, bassline_crypto`. It digests with `blake2b`, `sha256` and `keccak256` (nimcrypto), and signs and checks `ed25519` and `eddsa-blake2b` (monocypher 4.0.3 and its optional Ed25519 module, vendored in `nim/vendor` byte for byte as released). Its Ed25519 is the standard one, so any language's Ed25519 checks what it signs. `newKeypair` and `keypairFromSeed` make keys, `ed25519` unless asked for another, `publicKey` gives a keypair's or signature's key, and `digest`, `verifies`, `sign`, `signed` and `holds` do the work. `toNode` writes a digest, key, signature, signed value or keypair, and `toDigest`, `toPublicKey`, `toSignature`, `toSigned` and `toKeypair` read one, refusing what isn't one. A digest or signature in an algorithm or scheme it doesn't know reads, and doesn't verify. A keypair, `(keypair eddsa-blake2b SEED KEY)`, is the form the tools keep a key in on the holder's own machine. Its bytes agree with `legacy/blnim`'s, which its tests check. The live checked value, the track that keeps only signed values and the monitor are still to come.
- `legacy/blnim/src/bl/lib/crypto` is the earlier implementation, which the jam and `bl clave` (`tools/cli`) still run on.

```sh
cd dialects/crypto/nim
atlas install            # once: nimcrypto, into deps/
nim c -r tests/tcrypto.nim
```

The package finds `core/nim` and its dependencies through `nim.cfg`, so run `atlas install` in `core/nim` first.
