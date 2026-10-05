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

## Tests

`test/codec.test.ts` runs the corpus's `ce`, `reject` (with the exact reason, fed whole and a byte at a time) and `starved` cases, read from `corpus.json` through a small carrier reader in `test/carrier.ts`, and checks `corpus.blb` decodes to the cases and re-encodes byte for byte. Random values (`test/random.ts`) cover round trips, arbitrary chunking and order agreeing with CE bytes. The tests were checked for teeth by breaking the code: a renamed reason, the shorter-frame rule flipped, either length-tier edge moved, the BOM stripped, UTF-16 text order, no member-order check, no minimal-length check on the large form, the depth limit off by one, and exponent spellings each fail them.

`test/text.test.ts` reads `corpus.bl` and checks it against `corpus.json`, whole and in pieces of several sizes, and runs the `reads`, `refuses`, `incomplete` and `document` cases. Random values print and read back, flat and laid out. Dropping the duplicate check, never waiting at the end of the text, ignoring what follows a frame closing at the top, holding refusals back without bound, and printing `nil` bare each fail them.

## Building

```sh
pnpm install                       # from the repo root
pnpm --filter @bassline/blts typecheck
pnpm --filter @bassline/blts test
pnpm --filter @bassline/blts build # emits dist/
```
