# Bassline

Bassline programs can share **values** before they agree on what those values mean. A **track** is a program’s local working memory. Add a value to a track and, if the track accepts it, that occurrence is there for later readers. This works even if nobody was listening when it arrived.

To ask a question, read the entries the track still holds. A track can offer its own queries for the questions its readers ask often. Attach a **monitor** to follow changes, interpret a form of value it recognises (a **dialect**), or contribute an entry to another track.

For example, a room might keep `(build 433 failed)` before a task board knows what to do with it. If the board later learns that build target 433 names task `fix-433`, it can show the earlier failure under that task. A builder that adopts the convention can report its next failure as `(build fix-433 failed)`.

The [value specification](data-model.org) defines what implementations exchange. Start with the [Nim implementation](core/nim/README.md), where tracks and monitors are worked out.

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
