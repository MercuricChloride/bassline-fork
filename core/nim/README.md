# Bassline in Nim

This is the Nim implementation of Bassline, and the one the model is worked out in. It needs Nim 2.4, and its only dependencies are `bigints` and `petit-parser`, which `atlas install` puts in `deps/`. Import it whole with `import bassline`.

## Modules

- [`micro.nim`](src/bassline/micro.nim) is values and the nodes a running program holds. A `Value` is one of the nine kinds with its mark. A `Node` is `Plain` (a value) or `Bound` (a `Live` host object), and a frame's members are nodes, so a live object can stand anywhere a value can. A live object says what value it stands for through `reified`. `reify` replaces each live node it reaches through plain ones, leaving the live nodes inside what those stand for, and `reified` goes all the way. Integers are `BNum`, an `int` when it fits and a big integer when it doesn't. Dicts and sets are sorted sequences. The reader reads CE in pieces (`initReader`, `readCE`, `readEach`, `readAll`, `starved`), and `write` writes CE into any `Enc`, a string among them. A live node is refused by the writer, so a node is reified before it crosses an edge. `MaxDepth` and `MaxValueBytes` cap what the reader takes.
- [`text.nim`](src/bassline/text.nim) is the textual syntax: `Value.parse` for one value, `Value.parseMany` for a document, and `$` to print. The parsers it builds from (`basslineValue`, `basslineParser`, `basslineDocument`) take extensions tried before a symbol, for a dialect with words of its own.
- [`micro_macros.nim`](src/bassline/micro_macros.nim) is values written in Nim: `bl`, `blet` and `matchValue`.
- [`tracks.nim`](src/bassline/tracks.nim) is local working memory and the monitors that follow it.
- [`monitors.nim`](src/bassline/monitors.nim) is monitors most programs want. `Printer(to: FILE)` writes each change to a track as a value on a line of its own, `(added I N)` or `(revised I WAS NOW)`, `Absent` for a vacant slot. `Relay(into: TRACK)` offers to TRACK what the track it watches holds when it joins, then each addition, and no revision, since a revision is the holder's own. Relaying into a track whose `keeps` takes less filters what is relayed.

## Keeping and reading

Offer a node with `track.add(node)`. If `keeps` admits it, that call places the occurrence in a slot. A reader can come along later and inspect the slots or call a query defined on the track. Equal values can occupy separate slots. Slots are never renumbered and the track only grows, so a position names the same slot for as long as the track lives. What the slot holds can change by revision.

Attach a monitor when a reader also needs changes, with `monitor.track = room` or `room.up(monitor)`. Its `joined` method can inspect retained entries. It hears each admitted occurrence through `added`. An `add` during a write returns `Staged`. The track checks `keeps` when the contribution reaches its turn, after the current change has reached its monitors. An immediate `add` returns `Kept` or `Ignored`. A track hears its own writes through `keeps`, `added` and `revised` before any monitor does, so a track written as a subtype can keep an index its queries read. [Monitor example](examples/track.nim)

Whoever holds a track can revise what it holds, as a step of its own. `revise` takes a draft over the committed slots, where `it[i] = node` replaces a slot and `it.delete(i)` leaves it vacant. Nothing is moved or appended this way, and a revision isn't asked of `keeps`. A revision during another write raises.

## Materializing a dialect

A node can hold a value or a live Nim object. Here a dialect reader recognises a three-member build record and makes its target available to Nim code. The live reading keeps the original form so it can be written out again.

```nim
import std/sequtils
import bassline

type Build = ref object of Live
  form, target: Node

method reified(b: Build): Value = b.form.toValue

proc readBuild(n: Node): Node =
  matchValue n:
  of "(build $target $_)": Build(form: n, target: target).toNode
  else: n

iterator builds(room: Track): Build =
  for i in 0 ..< room.len:
    case room[i]
    of Present(n):
      if n.isBound and n.asLive of Build:
        yield Build(n.asLive)
    of Absent: discard

let room = Track()
let report = bl"(build 433 failed)"
room.add report
room.reviseIt:
  case it[0]
  of Present(n): it[0] = readBuild(n)
  of Absent: discard

let held = toSeq(room.builds)
doAssert held.len == 1
doAssert held[0].target == bl"433"
doAssert held[0].reified.toNode == report
```

Inside `reviseIt`, the draft sees earlier edits in the block and the track still exposes its committed entries. A successful revision with changes calls `revised` once. Each swap carries the slot and its previous entry, and the monitor can read the current entry from the track. A draft that raises discards its edits and any additions staged during the block. A hook that raises after commit leaves the change in place. The writer receives the first hook error after the remaining monitors and queued additions have had their turn.

## Values in Nim

`bl"…"` reads the textual syntax at compile time and builds the node it spells. `$name` splices a node bound in Nim, `$name!` marks it, and `@names` spreads a sequence of nodes into the list, record or set it stands in. A name is spelled as in bassline, so `$first-one` is `firstOne`, and `$p.x` is a field. A doubled sigil spells the symbol with one, so `$$x` is the symbol `$x`.

`blet` names values. A set of symbols names each symbol, so `blet "{ping serve-tcp}"` binds `ping` and `serveTcp`, and a dict names each value by its key.

`matchValue` tries `of "PATTERN":` branches in turn, among `elif` and `else`, and runs the first that fits with its holes bound. A list or record fits one of its kind, mark and length, or at least that length when it ends in a rest `&name`, bound as the members after. A dict or set fits one of its mark holding what it names. An atom fits an equal one. `$name!` fits only a marked value, `$_` and `&_` fit anything and bind nothing, and a live node fits only a hole. A pattern followed by `{any-mark}` fits its value whatever the value's mark. A branch naming a Nim value, `of ping:`, fits a subject equal to it.

```nim
matchValue entry:
of "(put $q $a)": echo q, " is answered by ", a
of "(row $head &rest)": echo rest.len, " more"
else: discard
```

`Dict` and `Set` put what they are given in order and keep one of each repeat. The text reader refuses a repeat instead. Editing a set's or dict's members in place re-sorts them, and raises when two have become equal, with the edit left in place.

## Tests and benchmarks

```sh
nim c -r tests/tcorpus.nim          # the shared corpus, every case head
nim c -r tests/t_micro_macros.nim   # bl, blet, matchValue
nim c -r tests/t_micro_values.nim   # live nodes, reify, writing
nim c -r tests/ttracks.nim          # tracks and monitors
nim c -r tests/tmonitors.nim        # printing and relaying
nim c -r -d:release bench/codec.nim [FILE.blb]   # round trips checked, then decode, encode and print timed
```

The benchmark runs over generated jam-shaped values, or over any `.blb` it is given.
