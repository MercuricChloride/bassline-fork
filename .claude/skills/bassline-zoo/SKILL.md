---
name: bassline-zoo
description: Implementing bassline in another language, making implementations interoperate, and building format doors (Pandoc-like conversion between bassline values and JSON, YAML, CSV, XML, Markdown and the rest). Use whenever someone wants bassline in Python, Rust, Go, TypeScript, Swift or any other language, a new reader or writer for bassline values, a document converter, or one implementation using another's capabilities — even if they only say "port", "binding" or "converter". Builds on the bassline skill, which holds the model; load that too.
---

# The bassline zoo

The zoo is bassline in many languages, interoperating. The point is not a set of ports. It is that a small implementation can use what a different implementation already has (signing, an evaluator, a format door) without porting it, because what crosses between them is only values. Python first; then whatever a real use calls for.

Load the `bassline` skill first: it holds the model (values, search and streams, sends, the edge). This skill is about building it somewhere new.

## What an implementation is

The bassline skill's three pillars, each small; the sections below take them in turn. Ergonomics matter as much as correctness: values should feel native in the host language, with literals where it has them, its iteration protocol for streams, its equality and hashing backed by CE bytes, and its printing showing the textual syntax. An implementation people avoid using interoperates with nothing.

## Pillar 1: values and encoding

What it needs, in build order, with the traps the existing ports hit: [references/checklist.md](references/checklist.md).

**The corpus is the agreement.** `corpus/corpus.bl` holds every case: values with their expected bytes, bytes to refuse with a reason, prefixes to wait on, and the reader's cases. Its bytes come from the spec, never from an encoder. Before your reader exists, bootstrap from `corpus/corpus.json`, the same cases in the kind-tagged JSON carrier, readable with any JSON parser that keeps integers exact (the checklist spells out its form). Run all seven case heads (`ce`, `reject`, `starved`, `reads`, `refuses`, `incomplete`, `document`) and check that `corpus.blb`, the same cases as a bare concatenation of CE, reads back as the cases.

## Pillar 2: working with values

- Construction that reads like the host language, and access that doesn't make people walk variant tags by hand.
- Walk, map and fold; `prefixes`; shapes (values with logical templates; the current form is naive and will change, so keep it small).
- Bridging host types: a host type gets readings in and out. Reading in refuses what it can't hold; it never coerces. A convenient default reading is fine as long as others can sit beside it, and local dispatch over host types is just local machinery, not the lookup-table smell.

## Pillar 3: search, sends, the edge

- A **search** is something you ask; it hands back a **stream** you pull. Keep them distinct in the API even when the host makes it easy to blur them: a search is a callable, a stream is the host's iterator. If the host has both synchronous and asynchronous iteration, pick one for streams and mirror the other only when a real use needs it.
- Stream combinators: `alt` (fair turns), `alt_from` (fair turns over a stream of streams, admitting newcomers lazily), `cat`, `map`, `filter`, `take`, and feeding answers into another search.
- A **send** is a callable that takes a value and may answer, as a host yes or no, whether it was understood.
- **Edge tools** read and write bare concatenations of CE on whatever byte channel is at hand: stdin and stdout, files, sockets. Nothing about the channel reaches program logic; inside, it appears only as values fed to local sends and sends offered out. Command-line tools follow the `bl` toolkit's conventions, including `bl magic` for format conversion: [references/cli.md](references/cli.md).
- How a search over what the edge feeds behaves when nothing has arrived yet (end, so the asker asks again later, or wait up to a bound the asker gives) is that search's choice.

## Interop

Implementations meet only through values at the edge.

- As within one program, nobody invokes someone else's search (the bassline skill's Negotiation). You send a value that leads the other side to search, and it sends what it finds somewhere you search over.
- The carrying is an edge tool: a pipe, a small local program that speaks between them, a socket. Choose per situation.
- What a capability is called, and how to ask for it, is a dialect the two sides happen to recognise.
- When a capability exists only as a library, someone writes that implementation's small program that takes values in and sends values out, knowing only values. blnim's signing has one: `bl-clave` (`packages/blcli`), run as `bl clave sign`, `verify` or `keygen`.
- Check first whether a capability reproduces natively. blnim's digests (BLAKE2b-256 and SHA-256 over CE bytes) do anywhere. Its signatures are monocypher's EdDSA over BLAKE2b, not Ed25519, so most hosts' libraries can't check them; those go through `bl-clave`.

A worked shape, in Python (blpy), signing through `bl-clave`:

```python
signed = Heard()                                        # local knowledge the edge feeds
signer = pipe(["bl", "clave", "sign"], into=signed.add) # edge tool, held by whoever runs it
to_signer = signer.send                                 # what program logic gets: a send

def signatures(v):
    """Answers from what has come back by each pull."""
    for s in signed.under(rec(sym("signed"), v)):
        if s.fields[0] == v:                            # the prefix narrows; equality decides
            yield s

to_signer(v)                    # True: handed on
list(signatures(v))             # perhaps [] now; asking again later sees what arrived
```

Answers are matched by what they carry, never by order or an ID, and program logic never holds the pipe.

The bar: a capability that exists only in implementation A gets used from implementation B through values alone, with no port of the capability and no binding between the two. A round trip of B's own values through a pipe shows nothing about interop.

## Format doors

Format conversion is a little compiler, like Pandoc but richer, and it is what lets an agent read anything in, work on it as values, and write anything out:

1. **A trivial first pass** reads a foreign document into values, close to an intermediate form but not quite one. It keeps everything the document says, in arrangements that hold it exactly, and refuses only what values cannot hold.
2. **Levers** are searches and sends over that artifact: reading dates as records, numbers as integers or `(dec …)`, renaming, dropping, restructuring, reinterpreting. A door may answer several readings of one document; the consumer picks.
3. **A writer** emits another format. Rendering is just another reading of values, and going out is lossy.

Bassline is the richer side of every conversion; never make a foreign format the baseline. The bar is empirical: conversion through bassline has to be measurably better than the alternatives. Per-format reading choices: [references/formats.md](references/formats.md).

## Writing it up

Each implementation lives in its own package: `packages/blnim`, `packages/blswift`, the JavaScript `packages/core`, and new ones as `packages/bl<lang>`. Each has a README in the manner of `packages/blswift/README.md`: usage, design notes on every choice that isn't obvious, differences from other implementations and why, what is deliberately not ported, and how the tests were checked for teeth (checklist, Tests).
