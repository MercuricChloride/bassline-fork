# Bassline

Bassline is a way for programs, people and agents to work together without first agreeing on what they mean.

Most ways of connecting programs begin with an agreement: a schema, an API, a message format, a topic name, who is on the other end. Whoever wasn't there when it was made can't join without changing it, and the meaning is settled before anyone knows what will turn out to be useful.

Bassline asks for one agreement only, on the bytes. Programs exchange values from one small grammar: nil, integers, text, symbols, bytes, lists, records, dicts and sets, any of them marked as something to do. Each value has exactly one spelling in bytes, and that spelling is its identity. What a value means is left to each reader.

A **dialect** is a way of arranging values that means something to the programs that recognise it, and it binds no one else. A program can say something before anyone knows what to do with it, a reader that learns a dialect later can make sense of what was said before, and two readers can read the same value in two dialects.

Nothing that takes part in a conversation has to understand all of it. Each program reads the dialects it cares about and lets the rest pass, keeping it or not as it chooses. So a new dialect can be spoken without anyone else changing, and a program supports exactly as much as it needs: an order others can cite, signatures, proof that something was said, parts of a value kept hidden, each taken up only where someone wants it.

For example, a build server might say `(build 433 failed)`. A program that knows builds acts on it, a log keeps it without knowing what it means, and a tool written next year reads what the log kept. If the server signs it, as `(signed (build 433 failed) SIG)`, a reader that cares who said it checks the signature, and one that doesn't reads the build inside it.

Inside a program, the construct for working with all this is the **track**, local working memory that keeps what the program hears. **Monitors** follow a track and read the dialects they recognise, and the program builds its understanding from what it holds.

The [value specification](data-model.org) defines what programs exchange. Start with the [Nim implementation](core/nim/README.md), where tracks and monitors are worked out.

## The repository

Code here is one of a few things: a kind of track, a monitor, a kind of live object, or a reading that turns what was said into live objects. Each serves a dialect, so the repository is organized by dialect rather than by language.

- [`data-model.org`](data-model.org) is the value specification, and [`corpus/`](corpus) the cases every implementation runs: values with their bytes, bytes to refuse, prefixes to wait on, and text to read.
- `core/` holds what every program needs to take part at all, one directory per language: values, their encoding, the textual syntax, tracks and monitors, and value literals in the host.
  - [`core/nim`](core/nim/README.md), where the model is worked out
  - [`core/ts`](core/ts/README.md), [`core/py`](core/py/README.md) and [`core/swift`](core/swift/README.md), which agree with it on values and their bytes and are still catching up on tracks
- `dialects/` holds one directory per dialect, with everything that speaks it in any language.
  - [`dialects/jam`](dialects/jam/plugin/README.md): rooms where people, agents and programs talk, and the plugin that puts Claude Code and Codex sessions on one
- `tools/` holds the [`bl` command line](tools/cli) and [editor support](tools/vscode/README.md) for `.bl` files.
- `legacy/` holds what the track model replaces, kept building while something still runs on it: [`legacy/blnim`](legacy/blnim), the earlier Nim implementation the jam and the `bl` tools run on today, and [`legacy/js`](legacy/js), the earlier JavaScript one.

[`AGENTS.md`](AGENTS.md) is the guide for working in the repository, for people and agents alike.

## Trying it

```sh
cd core/nim
atlas install              # once: the dependencies, into deps/
nim c -r tests/tcorpus.nim # the shared corpus
nim c -r tests/ttracks.nim # tracks and monitors
```

## License

AGPLv3
