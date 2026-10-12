# blts

A TypeScript implementation of the [bassline data model](../../data-model.org).

## Layout

- `src/` is the implementation, written so Node can run it directly: relative imports carry `.ts`, and only erasable syntax is allowed (no `enum`, `namespace` or parameter properties). `tsc` rewrites the imports to `.js` when it builds `dist/`.
- `test/` holds the tests, run by vitest. The shared corpus is `../../corpus`: `corpus.bl`, `corpus.json` and `corpus.blb`.

## Factories

The decoder and the text reader build values through a `Factory`, one constructor per kind, so neither is tied to a value implementation: they take one as their first argument (`new Decoder(value)`, `readValue(value, text)`), and whatever they need of a value comes through the interfaces in `types.ts`. `value` is the factory for this package's classes. A dict or set puts what it is given in canonical order and keeps one of each; the decoder hands members over already in order, the reader as written.

## The codec

`src/codec/` reads and writes the canonical encoding.

- `encode(v)` is a value's CE bytes; `encodeInto(v, buf)` appends them to a `ByteBuffer`.
- `Decoder` is resumable: `add` bytes in pieces of any size, pull `values()` for each value they now hold whole, and `finish()` once the input has ended, after which `values()` reports a value left open as `Incomplete`. Running out inside a value breaks no rule, so the decoder waits there. Every rule is checked as the bytes arrive, so a refusal is the first fault in byte order, and a decoder that refused stays refused. Values land as they are pulled: stopping early leaves the rest for the next pull.
- `decodeAll(bytes)` reads a bare concatenation given in total; `decode(bytes)` reads exactly one value, refusing none (`no-value`) or more (`several-values`), as the readers refuse empty text and text that has begun a second value. Input that ends inside a value throws `Incomplete`, never a `CodecError`.
- A `CodecError` carries a `reason`: the corpus's eleven, then `max-depth` and `max-value-bytes`. `maxValueBytes` caps a value's CE bytes counted from its header, refused as soon as the bytes seen show it is past: a scalar from its length, before its payload arrives.
- Decoded values are built, not borrowed: payload bytes are copied out, so the decoder lets go of landed bytes on the next `add`.
- Dict and set order is checked on the members' CE bytes. The value classes order structurally (`cmp`), which the tests check agrees with CE bytes; text orders by its UTF-8, so not by JavaScript's UTF-16 comparison.
- An integer decodes to a `number` when it is a safe integer, otherwise a `bigint`. A `number` past 2^53 is still an exact integer and encodes in full decimal, never with an exponent; a non-integer `number` is refused when the value is built, as is text with a lone surrogate.
- The decoder keeps its own stack of open frames because it has to stop wherever the bytes run out, frames deep, and carry on from there when more arrive; recursion would unwind and read the open frames again. That also makes `maxDepth` a plain check on untrusted input rather than a call stack overflow. The encoder always has the whole value in hand and never pauses, so it recurses, as `cmp` and the printer do; the values it meets come mostly from the decoder or the reader, whose depth limits bound them.

## Text

`src/text/` reads and prints the textual syntax.

- `Reader` takes text in pieces as the decoder takes bytes (`add`, `values()`, `finish()`), a port of blnim's. It hands back each value once the text so far certainly holds it: a value still open waits, and so does an atom or frame touching the end of the text, since what comes next may go on with it or mark it. It only reads again once the text has moved on at the top (or the unread text has doubled), so a long value arriving in pieces is read once, not on every piece. A refusal is a `ReadError` with a line and column; text that runs out inside a value is `ReadIncomplete`.
- `readValue` reads exactly one value; `readDocument` reads them all.
- The reader recurses through frames (a pause means reading the text again anyway), so it takes the decoder's `maxDepth` (default 1024) and refuses deeper text with a `ReadError` instead of overflowing the call stack.
- Set members and dict entries go to the factory as written, and the frame it builds puts them in order. A frame holding fewer members than were written was given one twice, and is refused.
- `print` spells a value on one line and `pretty` lays it out within a width, as blnim does; both read back as the value. A symbol is quoted when its bare spelling would read as something else.

## Literals

`` bl`(point ${x} [1 2])` `` reads the textual syntax as one value; `template(factory)` makes the same tag over another factory. The text is read raw, so escapes mean what they mean in `.bl` files.

- Each `${…}` is a value of its own wherever it sits (`` bl`[a${x}b]` `` is three members), and refused inside a quoted string or a comment. A mark on a splice, `${x}!` or `!${x}`, marks it; a spliced value keeps a mark it came with.
- A splice goes through `toValue`: a value passes as it is; an array is a list, its members brought across in turn; an object with a `[TO_VALUE](factory)` method brings itself across; an integer (`number` or `bigint`) is a number, a string is text, a JavaScript symbol is the symbol its description spells (`Symbol('go')` is `go`), and a `Uint8Array` is bytes, copied. Anything else, a boolean, `null`, `undefined`, a symbol with no description, a non-integer, is a `TypeError`: write nil or a set in the template, or splice a value built for it.
- `ops(factory)` binds the operations that build values to a factory: `bl`, `toValue`, `withMark` (the value with the mark set or cleared), `assoc` (a dict with entries added, a later one for a key standing, or a set with members added) and `dissoc` (a dict without some keys, or a set without some members). Each builds a new value; the one given is untouched.
- U+FFFC stands for a splice in the joined text, so a template may not contain it itself.

## Streams

A stream is a host iterator, a generator most often, so the platform's iterator helpers (`map`, `filter`, `flatMap`, `take`, `some`, `find`, `reduce`, `toArray`) work on every stream. `src/stream.ts` adds what the platform lacks, as blnim's `stream.nim` has it: `alt` (fair turns), `altFrom` (fair turns admitting one more stream a round), `cat` and `catFrom` (one after another), `merge` (in order, pulling a stream again only once its answer is taken), `filterMap`, `tap`, `just`, `empty`, `lazy`, and `stream(xs)` for the helpers on an array.

The platform's `take`, `some`, `every`, `find`, and a `for…of` that breaks, close the stream when they stop. `pull(s)` takes the next answer and `pull(s, n)` up to `n`, leaving the stream open to pull again.

## Shapes

`src/shape.ts` is a port of blnim's `queries/rewrite.nim`. A shape is an example value and a set of holes, written `(shape EXAMPLE {HOLE …})` or `(shape EXAMPLE {HOLE …} WILD)`; `shapes(factory)` gives `shape`, `shapeFrom` (reads one written down, refusing anything else with a `ShapeError`), `shapeValue` (writes one down), `fillings` and `inject`.

- `fillings(shape, v, given?)` is a little unification search: every binding of the holes, `{HOLE: VALUE …}`, under which `v` fits the example, extending the bindings `given`, one per pull and nothing worked out ahead. A list or record fits with at least the example's members; a dict or set member with a hole or the wild in it is tried against each of the value's keys or members, and one without is looked up. A hole fits a value of its own mark, a hole met again fits only what it is bound to, every hole must be bound, and each filling is answered once.
- The search for a frame takes its parts in the order blnim does: what the bindings already decide first, then what has one place to fit, then the part narrowest by its known leading members. A list or record member of a set is looked for only among those that begin with the members already known, found by bisecting (`ledBy`, over `ISet.from`).
- `inject(shape, bindings)` goes the other way: the example with each bound hole filled in and the rest left as they are.
- `v => fillings(shape, v)` is the shape as a search.

The tests port blnim's `trewrite.nim`, including its check against a brute-force search that tries every assignment of a value's parts to the holes, over 400 random small values with holes punched anywhere. They also count how many set members a search pulls, so the ordering and the bisecting are checked as well as the answers.

## JSON

`src/json/` is the kind-tagged JSON carrier, a port of `lib/json.nim` and of `@bassline/core/json`: each value is `{"kind": KIND, "mark"?: true, "value": …}`.

- `fromJson(factory, text)` reads text; `jsonToValue(factory, node)` reads JSON already parsed, or what `valueToJson` writes. `numberReviver` is the reviver they use, for reading a document holding several values with `JSON.parse`.
- `toJson(v, space?)` writes text; `valueToJson(v)` writes the plain JSON data, over `steps`, so a value deeper than the call stack still writes.
- Numbers are read from the parser's source text, so none is rounded: a safe integer is a number, a wider one a bigint, and anything that is not an integer spelling (`1.5`, `1e3`, `-0`) is refused. An integer past 2^53 is written as a raw JSON number, digit for digit.
- Dict and set members are read in any order and written in canonical order. A duplicate, an unknown key on the object, or a kind that isn't one is a `JsonError`, and so is nesting past `maxDepth`.

## Tests

`test/codec.test.ts` runs the corpus's `ce`, `reject` (with the exact reason, fed whole and a byte at a time) and `starved` cases, read from `corpus.bl`, and checks `corpus.blb` decodes to the cases and re-encodes byte for byte. Random values (`test/random.ts`) cover round trips, arbitrary chunking and order agreeing with CE bytes. The tests were checked for teeth by breaking the code: a renamed reason, the shorter-frame rule flipped, either length-tier edge moved, the BOM stripped, UTF-16 text order, no member-order check, no minimal-length check on the large form, the depth limit off by one, and exponent spellings each fail them.

`test/text.test.ts` reads `corpus.bl` whole and in pieces of several sizes, and runs the `reads`, `refuses`, `incomplete` and `document` cases. Random values print and read back, flat and laid out. Dropping the duplicate check, never waiting at the end of the text, ignoring what follows a frame closing at the top, holding refusals back without bound, and printing `nil` bare each fail them.

`test/json.test.ts` checks `corpus.json` reads as the cases in `corpus.bl`, that the cases write as `corpus.json` byte for byte, and that every case reads back with its dict and set members reversed. Random values write and read back as themselves, and the text is stable across a re-read. Dropping the duplicate check, allowing unknown keys, taking any JSON number, writing wide integers as doubles, always writing the mark, and dropping the depth check each fail them.

## Building

```sh
pnpm install                       # from the repo root
pnpm --filter @bassline/blts typecheck
pnpm --filter @bassline/blts test
pnpm --filter @bassline/blts build # emits dist/
```

## Objects

`src/object.ts` is a port of the second half of blnim's `queries/queries.nim`. An object is a marked set of records shaped as answers: an unmarked `(QUESTION ANSWER)` is something it answers, a marked `!(QUESTION ANSWER)` an order, such as its kinds `!(kind K)`. `isObject`, `toAnswer`, `headed` (a set's records under a head, found by bisecting), `answers` and `answer` (the first in CE order, for a reader that wants one), and `orders` read any object. `objects(factory)` gives what builds: `obj`, `answered`, `order`, `target`/`targets`, `kinds`, `hasKind`, and names: `identities`, `knownAs`, `sharesIdentity`, `identity`, `identityOf`, `randomId` (sixteen random bytes), `alsoKnownAs`, `describe`.

## Searches

`src/search.ts` is a port of blnim's `queries/search.nim`. A `Search` is what you ask: `ask(q)` hands back a stream, `first(q)` the first answer. One may write its space down (`toValue`) and say the ID it goes by (`id`) without writing it down; `byId` writes it down by its ID alone. A plain function `q => Iterable` asks like one (`asSearch`). `searches(factory)` gives `search`, `cat` (a part asked only once the one before has nothing more), `alt` (fair turns), `feed` (each answer asked on), `searchOver` (a set of records or a dict held now) and `fromValue`, which reads a denoted space back: `holds` sets and dicts, `cat`/`alt`/`feed` composites, and names resolved through a search of known spaces when asked, a name met again on its own way round passed over. Ranked spaces and `merge` are not read yet; `fanout` is not ported.

## Scopes

`src/scope.ts` holds the searches in reach where a question comes up. A question is named (`question<Q, A>('showing')`); the types ride along for TypeScript only, so two questions with one name are one. `put(q, search)` puts a search in a scope for a question; asking there (`ask`) asks every search in reach for it, nearest first: the scope's `nearer` scopes, reached when a question gets there, then its own in the order put, then its parent's. Searches are asked lazily, so the first answers come in that order; then each live stream gives one answer a round, so no endless one starves the rest. `first`, `reach` (each search with where it was found), `replay` (who answers, each with its first answer) and `search(q)` (the question as one search) build on it. Nothing is asked ahead of a pull, and a pull sees the scopes as they are then. `read` and `changed` are hooks for whatever watches a scope.
