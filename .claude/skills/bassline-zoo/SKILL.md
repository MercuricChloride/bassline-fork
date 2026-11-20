---
name: bassline-zoo
description: Implementing bassline in another language, making implementations interoperate, and building format doors (Pandoc-like conversion between bassline values and JSON, YAML, CSV, XML, Markdown and the rest). Use whenever someone wants bassline in Python, Rust, Go, TypeScript, Swift or any other language, a new reader or writer for bassline values, a document converter, or one implementation using another's capabilities — even if they only say "port", "binding" or "converter". Builds on the bassline skill, which holds the model; load that too.
---

# The bassline zoo

Implementations interoperate through values. A small implementation can use another’s signer, evaluator, or format door by exchanging values it knows how to read. Use the [Bassline model](../bassline/SKILL.md) for tracks, monitors, and local dialect readings.

## Values and encoding

What it needs, in build order, with the traps the existing ports hit: [references/checklist.md](references/checklist.md).

**The corpus is the agreement.** `corpus/corpus.bl` holds every case: values with their expected bytes, bytes to refuse with a reason, prefixes to wait on, and the reader's cases. Its bytes come from the spec, never from an encoder. Before your reader exists, bootstrap from `corpus/corpus.json`, the same cases in the kind-tagged JSON carrier, readable with any JSON parser that keeps integers exact (the checklist spells out its form). Run all seven case heads (`ce`, `reject`, `starved`, `reads`, `refuses`, `incomplete`, `document`) and check that `corpus.blb`, the same cases as a bare concatenation of CE, reads back as the cases.

## Working with values

- Construction that reads like the host language, and access that doesn't make people walk variant tags by hand.
- Walk, map and fold; `prefixes`; shapes (values with logical templates; the current form is naive and will change, so keep it small).
- Bridging host types: a host type gets readings in and out. Reading in refuses what it can't hold; it never coerces. A convenient default reading is fine as long as others can sit beside it, and local dispatch over host types is just local machinery, not the lookup-table smell.

## Local working memory

For an application runtime, expose a track in the host language. An admitted addition stays in the track’s local order. A reader that starts later can inspect the entries still held. Implement queries as methods, functions, or iterators over the track. Attach monitors for ongoing reactions. A value codec or format door can interoperate on CE alone. `core/nim` is the reference, and the other cores don't have tracks yet. [Nim reference](../../../core/nim/README.md)

At the edge, read and write self-contained values as a bare concatenation of CE. A local monitor can write values to an output, and a decoder can contribute arrivals to a track. Choose the carrier at the edge. [CLI conventions](references/cli.md)

## Interop

Implementations meet only through values at the edge.

- Each side decides what to keep and how to read it. If one wants the other to do something, express it as a value the other can recognise.
- The carrying is an edge tool: a pipe, a small local program that speaks between them, a socket. Choose per situation.
- What a capability is called, and how to ask for it, is a dialect the two sides happen to recognise.
- When a capability exists only as a library, someone writes that implementation's small program that takes values in and sends values out, knowing only values. blnim's signing has one: `bl-clave` (`tools/cli`), run as `bl clave sign`, `verify` or `keygen`.
- Check first whether a capability reproduces natively. blnim's digests (BLAKE2b-256 and SHA-256 over CE bytes) do anywhere. Its signatures are monocypher's EdDSA over BLAKE2b, not Ed25519, so most hosts' libraries can't check them; those go through `bl-clave`.

In the existing Python adapter, the edge feeds what `bl-clave` writes into `Heard`, and a local function reads the signatures from it. Answers are matched by what they carry, never by order or an ID, and program logic never holds the pipe.

```python
signed = Heard()                                        # local knowledge the edge feeds
signer = pipe(["bl", "clave", "sign"], into=signed.add) # edge tool, held by whoever runs it

def signatures(v):
    """Answers from what has come back by each pull."""
    for s in signed.under(rec(sym("signed"), v)):
        if s.fields[0] == v:                            # the prefix narrows; equality decides
            yield s

signer.send(v)                  # blpy's pipe writer accepts the value for carriage
list(signatures(v))             # perhaps [] now; asking again later sees what arrived
```

Here `signatures(v)` matches the value inside each signed record. It can run again after more output arrives.

The bar: a capability that exists only in implementation A gets used from implementation B through values alone, with no port of the capability and no binding between the two. A round trip of B's own values through a pipe shows nothing about interop.

## Format doors

Format conversion is a little compiler, like Pandoc but richer, and it is what lets an agent read anything in, work on it as values, and write anything out:

1. **A trivial first pass** reads a foreign document into values, close to an intermediate form but not quite one. It keeps everything the document says, in arrangements that hold it exactly, and refuses only what values cannot hold.
2. **Levers** let a reader choose how to interpret or transform the artifact, such as reading dates as records or numbers as integers or `(dec …)`. A door can offer several readings of one document.
3. **A writer** emits another format. Rendering is just another reading of values, and going out is lossy.

Bassline is the richer side of every conversion; never make a foreign format the baseline. The bar is empirical: conversion through bassline has to be measurably better than the alternatives. Per-format reading choices: [references/formats.md](references/formats.md).

## Package documentation

Each implementation of the shared grammar lives in `core/LANG`: `core/nim`, `core/ts`, `core/py` and `core/swift` today, and a new one beside them. The earlier `legacy/blnim` and `legacy/js` stay for reference. A participant of one dialect, in any language, goes in `dialects/NAME` instead. Each implementation has a README in the manner of `core/swift/README.md`: usage, design notes on every choice that isn't obvious, differences from other implementations and why, what is deliberately not ported, and how the tests were checked for teeth (checklist, Tests).
