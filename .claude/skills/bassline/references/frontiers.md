# Frontiers

Hard but useful work, from a maintainer's point of view. Each item says what it is and what it touches. None of it is a schedule.

## Search as its own module

`queries/search.nim` has `Search[Q, A]`, denoted spaces, and composition (`cat`, `alt`, `feed`, `merge`, with denotations that carry parts whole or by ID); `queries/bvar.nim` and `lib/bvarfile.nim` have bvars with memoising and file persistence (search.md, "Denoted search spaces"). Still open: whether "bvar" is the right name for a place to put and search; thread safety of a bvar's halves (they are closures over shared containers, unsynchronised); spaghetti stacks of closures as values on top of named spaces; a richer stream protocol in place of the per-pull `Option`. Denoting a runtime thing could be something asked rather than something it has: a `BVar[T, Value]` keeping how things are denoted, plural and per environment, and a `BVar[Value, T]` which thing a denotation reaches; today a space uses its answer type's one `toValue`/`fromValue`. A bvar read back pairs its send with a live copy only of a space given directly as its search, not of one inside a composite. `fold`, `scan` and `latch` are typed as plain functions but keep state, and Nim's `alt` re-pulls a finished stream where Swift's drops it.

## Shape matching as a search

A shape is a value with a logical template in it, and matching is a search that answers every filling. blnim's `queries/rewrite.nim` and blswift's `Shape.fillings(of:)` both answer every binding, one per pull, trying holes in dict keys and set members against each actual key or member, and treating a repeated hole bound two ways as no filling rather than an error; blnim's can start from bindings already had and is a `Search` (`search(shape)`). Still open: unification with holes on both sides, a denotation for a shape's search, and the `(shape example holes)` record, a naive form that will change.

## The jam

`lib/jam.nim` with `bl-jam` (`packages/blcli`) and `packages/jam-plugin`: rooms where people, agents and programs talk, the protocol being `(Q A)` puts and `(Q)` asks. Still open:

- **Richer questions.** A question is a value, so a jam could answer a denoted search (a cat or merge of rooms) or a shape. Today it answers only by name.
- **History on rejoin.** Asking tells everything a question holds, so a reader that comes back is told it all again. There is no question for "after R" yet.
- **Stopping.** A line can't say it has stopped asking; a client just hides the room.
- **Presence.** `(gone …)` is put when a line stops speaking or a tell is refused. A machine that vanishes without closing its connection is noticed only when a tell fails; and a pipe that has stopped speaking but goes on hearing counts as gone.
- **Relays.** One jam relaying into another would be idempotent, since an answer is its CE, but no relay is built.
- **Privacy.** Everything said is readable by everyone on the jam, `(for NAME)` included; observability is the point, and privacy would be a dialect on top (sealed values).
- **Log size.** The log only grows.

## Evaluators as searches

A lambda-calculus search is the first worked case (search.md, "Evaluation"). Grading strategies by an objective, and online algorithms, sit on top.

## The zoo and format doors

Designed in the `bassline-zoo` skill. `packages/blpy` is the Python implementation and provides `bl-magic`, the first converter: doors for JSON, CSV, TSV, TOML, XML, YAML, the textual syntax and the carrier, with levers as searches. Markdown, SQLite, CBOR and EDN doors are next. The kind-tagged JSON dialect stays the simple carrier. blnim's signing is reachable from anywhere through `bl-clave`.

## Interfaces

A native interface whose views, actions and search are searches over the values on screen (search.md, "Interfaces").

## Scouts

Unbuilt and still loose; the idea is in SKILL.md, "Scouts".

## Search from the command line

`bl search` (`packages/blcli`) makes searches reachable from a shell, with downstream reading as the pull: builtins `under` and `walk`, and any `bl-search-NAME` on PATH, which is how blpy's levers join. `bl search match`, shape matching from the shell, can now be built on `rewrite.nim`'s fillings (or be a `bl-search-match` from another implementation). See the `bassline-zoo` skill's `references/cli.md`.

## The data model document

`data-model.org` is load-bearing: every change needs an explicit instruction, and the corpus and all implementations follow it. Gaps between its prose and what the corpus and readers do:

- It lists end of input inside a value among the rejections. For input given in total that holds, but the corpus reports it apart from the rule-breaking reasons (`starved`, `incomplete`), because a reader still being given more waits there instead. The corpus header says so; `data-model.org` doesn't.
- It lists four escapes; the readers and the corpus also accept a backslash before the closing quote.
- It doesn't say how adjacent marks read: `go!!(a)` reads as `go!` and `!(a)`.

## Parked

- The store (`bl/store`): an exploration that will change; don't build on it now.
