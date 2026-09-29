# blswift

A small Swift implementation of the [bassline data model](../../data-model.org): an in-memory `Value`, the canonical binary encoding (encoder plus streaming decoder), the textual syntax (reader and printer), shapes for matching and building values, a protocol for bridging your own Swift types, and an `AsyncSequence` adapter for byte streams.

It passes every case in the shared corpus (`../../corpus`): all 143, with the exact reason for each rejected input.

```swift
import Bassline

let message: Value = .record("msg", "hello", 42, ["k": .symbol("v")], Value.symbol("go").marked)
message.description      // (msg "hello" 42 {"k": v} go!)
try message.encoded()    // [0x70, 0x43, 0x6d, 0x73, 0x67, …, 0xa0]

let same = try Value(decoding: try message.encoded())
same == message          // true — identity is the canonical bytes
```

- [Requirements](#requirements)
- [Usage](#usage)
- [Design notes](#design-notes)
- [Testing](#testing)
- [Limitations and future work](#limitations-and-future-work)

## Requirements

- Swift tools 6.3 or later, Swift 6 language mode
- Platforms `.v26`: macOS, iOS
- Foundation for testing

Add it to an Xcode project through **File ▸ Add Package Dependencies ▸ Add Local…**, or from another package:

```swift
.package(path: "../bassline/packages/blswift"),
// …
.target(name: "App", dependencies: [.product(name: "Bassline", package: "blswift")]),
```

## Usage

### Building values

```swift
// literals: integers (any size), strings (as text), arrays (as lists), dictionaries
let n: Value = 123456789012345678901234567890
let list: Value = [1, "two", [3]]
let dict: Value = ["name": "alice"]

// factories mirror the kinds
let go = Value.symbol("go")
let point = Value.record("point", 1, 2)                   // (point 1 2)
let general = Value.record(head: [1], fields: ["x"])       // ([1] "x")
let tags = Value.set([.symbol("red"), .symbol("blue")])   // {red blue}, kept in canonical order
let blob = Value.bytes([0xde, 0xad])

// the mark is a bit you can flip
let request = Value.record("insert", tags).marked          // !(insert {red blue})
request.unmarked == Value.record("insert", tags)           // true
```

There are deliberately no `Bool`, `Float` or `nil` literals: `let v: Value = true` doesn't compile. The data model leaves those to dialects, and so does the compiler.

### Reading values

Pattern match on `content`, or use the optional projections:

```swift
switch value.content {
case .record(let head, let fields) where head == .symbol("point"):
    print("a point with \(fields.count) fields")
case .integer(.int(let n)):
    print("a small integer", n)
case .integer(.big(let spelling)):
    print("a big integer", spelling)
default:
    break
}

value.head          // Value? — the record head
value.fields?.first
value.dict?[.symbol("name")]?.text
value.isMarked
```

### Integers

`Value.Integer` is an `Int64` when it fits, and its canonical decimal spelling otherwise:

```swift
public enum Integer { case int(Int64), big(String) }

Value.Integer(UInt64.max)                 // .big("18446744073709551615")
Int8(exactly: Value.Integer.int(128))     // nil — conversions are exact or nothing
Value.Integer(spelling: "007")            // nil — only canonical spellings
```

`Value.Integer` is `Comparable` in **numeric** order. `Value` itself is not `Comparable`; see [canonical order](#canonical-order-without-comparable).

### Dicts and sets

`Value.Dict` and `Value.Set` keep their members in canonical order, so iterating, printing and encoding them is deterministic from run to run. (Swift's own `Dictionary` iterates in a different order in every process.) Lookups, inserts and removals are O(log n), copies are O(1), and editing a copy only copies the few nodes on the edited path. See [collections](#collections-a-copy-on-write-b-tree).

```swift
var dict: Value.Dict = [0: "zero", 1: "one"]
dict[0]                 // "zero" — a key lookup, not a position (indices are opaque)
dict[1] = nil           // removes the key: silence
dict[2] = .null         // keeps the key, stating the value is absent
for (key, value) in dict { … }

var set: Value.Set = [3, 1, 2]
set.insert(4).inserted  // true
set.contains(2)         // O(log n)
```

Duplicate keys in a dict literal trap, as they do for `Swift.Dictionary`. Duplicate members in a set literal also trap, matching the text reader, which refuses `{1 1}`. `init(_:)` from a sequence deduplicates instead (last write wins for dicts). Reaching a position (`dict[index]`) is O(log n); iterating is O(1) per element.

### Editing in place

Pulling a payload out with `if case .dict(var d) = value.content` leaves the enum holding a second reference, so the first edit to `d` copies the whole dict. Use the mutators instead. They move the payload out first, so edits land on the only reference, and they compose with `Value.Dict`'s subscript, which also edits in place:

```swift
value.withDict { dict in
    dict[.symbol("users")]?.withList { $0.append(.record("user", 1)) }
    dict[.symbol("count")] = 1
}
request.withRecord { head, fields in fields.append(2) }   // the mark is kept
```

`withDict`, `withSet`, `withList` and `withRecord` return `nil` without calling the closure when the value is another kind.

### Binary encoding

```swift
let bytes: [UInt8] = try value.encoded()
try value.encode(into: &buffer)          // append; back-to-back values form a stream

let one = try Value(decoding: bytes)     // exactly one value (Data works too)
let all = try Value.decodeAll(stream)    // every value, ending on a boundary
```

Both directions honour the same `Limits` (`maxDepth`, default 64, and `maxValueBytes`, default 100 MiB). The encoder throws `EncodeError` (`too-deep` or `too-large`) for any value a decoder with the same limits would refuse, and leaves the buffer untouched when it does. Pass `limits:` to either side to raise or lower the line.

Decoding throws a typed `DecodeError` with a `reason` and a stream `offset`. The reasons' raw values are the corpus's names for them:

```
invalid-tag  end-with-bits  end-at-top  length-bits  non-minimal-length
bad-integer  bad-utf8  empty-record  stranded-key  out-of-order  duplicate
too-deep  too-large  truncated  trailing-bytes
```

### Streaming

`StreamDecoder` takes bytes however they arrive. It tells apart bytes that are **wrong**, which it refuses by throwing, from bytes that are only **the start of a value**, which it waits on by returning `nil`:

```swift
var decoder = StreamDecoder(limits: Limits(maxDepth: 64, maxValueBytes: 1 << 20))
decoder.append(contentsOf: chunk)          // any Sequence<UInt8>, or a Span<UInt8>
while let value = try decoder.next() {     // nil: waiting for more bytes
    handle(value)
}
// at end of input
try decoder.finish()                       // throws `truncated` if a value was left unfinished
```

Once a decoder throws, it keeps rethrowing the same error. The encoding has no framing to resynchronise on.

Any async byte stream can be read directly:

```swift
for try await value in url.resourceBytes.basslineValues() { … }
for try await value in fileHandle.bytes.basslineValues() { … }
```

### Text

```swift
let v = try Value(reading: "!(insert {(person alice) (person bob)})")
let doc = try Value.readDocument("; a comment\n1 2 [3]")   // [1, 2, [3]]
v.description                                                // prints it back on one line
```

`ReadError` separates text that is **refused** from text that is **incomplete** (`isIncomplete`: the input stopped where more could still make it valid, as in `[1 2`). A REPL or editor can use that to keep reading. Errors carry a UTF-8 byte `offset` plus a 1-based `line` and `column` (the column counts Unicode scalars).

Printing and reading are inverses: `Value(reading: v.description) == v` for every value, which the tests check on random values.

### Bridging your own types

```swift
struct Point: ValueConvertible {
    var x: Int, y: Int

    init(x: Int, y: Int) { self.x = x; self.y = y }

    var basslineValue: Value { .record("point", Value(x), Value(y)) }

    init(bassline value: Value) throws {
        guard !value.isMarked, value.head == .symbol("point"),
              let fields = value.fields, fields.count == 2 else {
            throw ValueConversionError(expected: "(point x y)", found: value)
        }
        x = try Int(bassline: fields[0])
        y = try Int(bassline: fields[1])
    }
}

Value(Point(x: 1, y: 2))        // (point 1 2)
```

Conformances included:

| Swift type | Value |
| --- | --- |
| `Value`, `Symbol`, `Value.Integer` | themselves |
| `String` | text |
| `Int`…`Int128`, `UInt`…`UInt128` | integer (exact, or it throws) |
| `Array` where `Element` conforms | list |
| `Optional` where `Wrapped` conforms | `nil` ↔ `.null` |
| `Swift.Set`, `Dictionary` where the members conform | set, dict |

Converting back is strict. A marked value is never read as its unmarked counterpart, and a `Swift.Set` or `Dictionary` throws if distinct bassline members collapse under Swift's equality (see [Unicode](#text-is-bytes-not-swift-strings)). `[UInt8]` becomes a list like any other array; bytes are always explicit, via `.bytes(_:)`.

### Shapes

A shape is an example value with holes, after blnim's `rewrite.nim`. It reads values that look like the example, binding each hole to what's in its position, and it builds values by putting a binding into every hole. As a value it's written `(shape example {holes})`, or `(shape example {holes} wild)` with a wild that matches anything and binds nothing.

```swift
let bookmark = try Shape(bassline: Value(reading: "(shape (bookmark url title) {url title})"))
// or: Shape(.record("bookmark", .symbol("url"), .symbol("title")), holes: [.symbol("url"), .symbol("title")])

try bookmark.extract(from: try Value(reading: #"(bookmark "https://…" "Docs" extra)"#))
// {url: "https://…" title: "Docs"}      — nil if the value doesn't fit
try bookmark.matches(value)               // Bool
switch value { case bookmark: …; default: … }

try bookmark.inject([.symbol("url"): "https://…", .symbol("title"): "Docs"])
// (bookmark "https://…" "Docs")         — every hole needs a binding
```

Matching rules:

- A hole binds the value in its position when their marks agree: a hole `x` binds unmarked values, a hole `x!` marked ones.
- A hole that occurs twice must bind equal values. Binding it to two different values throws `ShapeError` (`mismatched-hole`).
- Everything else matches literally: kinds and marks must agree, and atoms must be equal. A marked atom like `go!` in an example matches only `go!`.
- Lists and records match position by position, heads included, and **extras are ignored**: the value may have more trailing members, dicts more keys, and sets more members. A dialect can grow without breaking the shapes that already read it. A value with fewer members than the example doesn't match.
- `extract` gives bindings only when every hole is bound.
- A hole is atomic: in `(shape (foo x (k x)) {x (k x)})`, the hole `(k x)` binds whole and the `x` inside it plays no part.
- Dict keys and set members are looked up literally, and nothing inside them binds. Reaching one that is itself a hole throws (`hole-in-key`, `hole-in-member`), since those are found by equality rather than position.
- `inject` throws `unbound-hole` unless every hole has a binding; bindings for other names are ignored. It fills every position, dict keys and set members included.

## Design notes

These are the decisions that aren't obvious from the API, and why they went the way they did.

### Why not Codable

Codable was the obvious candidate, and it's the wrong foundation here. Its data model assumes a schema:

- containers keyed by strings;
- `Bool` and `Double` as primitives;
- no mark;
- no difference between symbol and text, or between record and list;
- `Set` encodes as an array;
- synthesized `Optional` properties skip the key (silence) instead of stating absence;
- the encoder never sees type names, so it can't produce `(point 1 2)`.

Building on it would bake one dialect into the encoder and quietly drop the distinctions the data model exists to keep.

So `Value` is the foundation, and Swift types opt in through `ValueRepresentable` / `ValueConvertible`, much as `CustomStringConvertible` and `LosslessStringConvertible` work. Each type chooses what it means in bassline: its head, its fields, whether it's marked. A Codable adapter could still be added later, labelled as one opinionated dialect ("structs are dicts keyed by symbols").

### Text is bytes, not Swift strings

The spec says text is well-formed UTF-8 _without normalization_. Swift's `String` equality and hashing use Unicode canonical equivalence: `"\u{e9}" == "e\u{301}"` is `true`, and the two hash the same. In bassline they are different values with different bytes.

So nothing in the library uses `String ==`, `String.hashValue` or `String <` for identity. Equality, hashing and ordering all go through UTF-8 bytes, and `Symbol` has its own byte-wise `==`. On Apple platforms this matters in practice: some filesystem APIs return names decomposed while keyboard input is precomposed, so two symbols can look identical and not be.

The printer walks Unicode scalars rather than `Character`s. `"\r\n"` is one `Character`, and so is a `"` followed by a combining accent, so matching on `Character` would miss both the escape and the quote.

### Canonical order without `Comparable`

Dicts and sets need a total order across all kinds, and CE byte order is the one the spec defines. It isn't a _natural_ order, though: integers sort by the length of their decimal spelling, then by its digits (`1 < 9 < -1 < 10`). Conforming `Value` to `Comparable` would make `max([-100, 5])` return `-100` and `Value(1)...Value(10)` contain `-1`.

Instead there is `Value.canonicalCompare(_:_:)`, a three-way comparison, and `Value.canonicalOrder` for `sorted(by:)`. `Value.Integer` is `Comparable` numerically.

`canonicalCompare` compares the structure directly instead of encoding. It relies on three facts:

- The header byte orders kind first, then the mark.
- Scalar lengths grow monotonically across the length tiers.
- A shorter frame sorts _after_ a longer one it's a prefix of, because END (`0xA0`) is greater than every header.

Two checks guard this: the tests compare it against the actual bytes on random values, and a debug assertion cross-checks it on every decoded dict and set.

### Canonical by construction

Wherever possible, a `Value` can't hold something non-canonical:

- a record's head isn't optional, so an empty record can't be built;
- integer spellings are validated byte by byte (Swift's own `Int("+5")` and `UInt8("-0")` are too lenient to use as a check);
- dicts and sets stay sorted and unique.

The encoder is therefore a plain walk that can't emit invalid bytes. Swift's value semantics also make cycles impossible, which the spec requires.

### Collections: a copy-on-write B-tree

Why not just make `Dict` and `Set` classes? The slow part of a sorted array is shifting elements on insert, and a class has the same cost. What a class would change is sharing: editing a dict inside one `Value` would change it inside every other `Value` holding it. Keys could also be mutated while inside a set or dict, breaking its order. `Sendable` would need locks, and a dict could contain itself, which the spec forbids. blnim uses refs because assigning a Nim `seq` deep-copies; Swift arrays are already copy-on-write, so that reason doesn't carry over.

So the storage is a B-tree (`CanonicalTree`) whose **nodes** are classes while the tree keeps value semantics:

- A mutation makes the path it touches uniquely referenced (`isKnownUniquelyReferenced`), copying only those nodes. Everything else stays shared with other copies of the tree.
- Nodes hold up to 63 elements, so a collection of up to 63 members is a single sorted array.
- Each node records its subtree's size, so the element at a given position is found in O(log n). That keeps `Dict` and `Set` random-access collections.
- The decoder, which gets members already in order, builds densely packed trees in O(n) without comparing anything.

Release-build measurements with 100k entries, against the earlier sorted-array version:

| operation | sorted array | B-tree | `Swift.Dictionary` |
| --- | --- | --- | --- |
| insert 100k keys one at a time | 1,686 ms | 69 ms | 16 ms |
| `Dict(pairs)` | 1,703 ms | 78 ms | – |
| 100 edits to a shared copy | 96 ms | 0.17 ms | – |
| 100 naive edits through `value.content` | 97 ms | 0.13 ms | – |
| look up every key | 51 ms | 60 ms | 8 ms |
| encode / decode | 3.6 / 7.7 ms | 5.4 / 9.6 ms | – |

Full traversals cost about 1.3–1.5× what a flat array does; everything that mutates got dramatically cheaper. Apple's own B-tree collections (`SortedSet` and `SortedDictionary` in swift-collections) are the same idea, but they're still behind an unstable trait. Swapping them in later would only change the private storage.

### Silence vs stated absence

Swift's `Optional<Value>` maps onto the model's three states directly. `nil` is silence and `.null` is stated absence, so `dict[k] = nil` removes a key while `dict[k] = .null` asserts that its value is absent. The bridge follows suit: `Optional.none` becomes `.null`.

### The streaming decoder

- **Resumable, no recursion.** It is an explicit-stack state machine, so feeding it one byte at a time costs the same as feeding it everything at once. That matters because `AsyncBytes` delivers bytes one at a time. Deep nesting can't overflow the call stack either.
- **Ordering checked on the raw bytes.** Set and dict ordering is checked on the bytes as they arrived, without re-encoding anything.
- **Limits.**
  - The depth limit (default 64, matching blnim) is required by the spec. The encoder and text reader enforce the same `Limits`, and the encoder checks size before depth just as the decoder does, so a refused value gets the same reason on both sides (property-tested).
  - The size limit (default 100 MiB) is judged from headers alone, so the verdict doesn't depend on how the input was chunked. A 4 GiB length header is refused before any payload arrives.
  - One-shot decoding raises the size limit to the input's length, since the caller already holds those bytes.
- **Precedence.** The first fault in stream order is the one reported. One-shot decoding reads everything before complaining about extra values. That way `[]` followed by a stray END reports `end-at-top`, and `trailing-bytes` only means that well-formed values followed.
- **Compaction.** Consumed bytes are dropped once they make up half the buffer, and only between values. Error offsets stay absolute stream offsets.

### Where `Span` is (and isn't) used

With the `.v26` floor, the decoder checks UTF-8 with `UTF8Span(validating:)`, which is strict and reports where the bad byte is, and it accepts input as a `Span<UInt8>`. Internally, the decoder and reader index plain `[UInt8]` arrays. A `Span` can't be kept as stored state in a decoder without experimental lifetime annotations, and array indexing is just as bounds-checked.

### Shapes, compared with blnim

The semantics are `rewrite.nim`'s, with two fixes:

- **A value shorter than the example doesn't match.** `rewrite.nim` compares list members pairwise up to the shorter length, so a value missing trailing members still passes; here the value needs at least the example's members, while extras are still ignored.
- **Nothing inside a dict key or set member binds.** `rewrite.nim` binds each found key against itself (`ensureBind(k, k)`), so a hole nested in a key, like `x` in `{(k x): 1}`, got bound to itself.

Its `Match` object and helpers (`maybeInject`, the `@` / `//` operators) aren't ported; `extract`, `inject` and `matches` cover them. blnim's earlier design, in the commented-out `tops.nim` tests, made every marked atom a hole instead of listing holes; that would make a literal `go!` impossible to match, and marked values are exactly what interpreters want to accept.

### Text reader

- **`Value(reading:)` requires exactly one value.** It reads the whole document first and then insists on exactly one value, like the one-shot binary decode. So `go !` is _incomplete_ (the trailing `!` is waiting for a frame) while `1 2` is _refused_. `""` is refused as "not one value"; `readDocument("")` returns `[]`. Both take `limits:`, and refuse text nested past `maxDepth`.
- **It's a labelled initializer, not `LosslessStringConvertible`.** That protocol's `init?(_: String)` would take over `Value("hello")` from the bridging initializer and read `hello` as a symbol instead of text.
- **String literals are text.** Swift has one kind of quoted literal and bassline has two, so use `Symbol` (`ExpressibleByStringLiteral`) wherever a name is meant. Record heads take a `Symbol`, which is why `.record("point", 1, 2)` reads naturally.

## Testing

```sh
swift test
```

The tests use Swift Testing and were developed against Xcode 27's toolchain (Swift 6.4). When `xcode-select` points at the Command Line Tools instead, `swift test` may fail with `no such module 'Testing'`. Point it at Xcode's toolchain instead:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
# or once, for good: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

What's covered:

- **The corpus, three ways.** `corpus.blb` (read by our decoder), `corpus.bl` (read by our text reader) and `corpus.json` (built by hand with Foundation) must produce the same 143 records. Dict and set members from the JSON are inserted shuffled, so the collections have to sort them themselves.
- **Re-encoding.** Encoding the records again must reproduce `corpus.blb` byte for byte.
- **Binary cases.**
  - `ce` cases are checked whole and one byte at a time. Nothing may land before the last byte.
  - `reject` cases must report the corpus's exact reason, whole and one byte at a time.
  - `starved` cases must wait without refusing.
- **Text cases.** `reads`, `refuses`, `incomplete` and `document` are all checked, with refused and incomplete told apart.
- **Property tests** (seeded random values, all kinds and marks, big integers, long payloads, awkward text):
  - encoding round-trips, including back-to-back and ragged-chunk streams;
  - printing and reading round-trip;
  - `canonicalCompare` matches byte order;
  - `==` matches equal bytes, and equal values hash the same;
  - under random limits, the encoder refuses exactly the values the decoder refuses, with the same reason.
- **The B-tree.** A randomized comparison against a sorted-array model at node sizes 3, 4, 5, 8 and 64, which forces splits, rotations and merges. A checker verifies every invariant: key order and bounds, node fill, uniform leaf depth and subtree counts. Packed builds are checked at every size from 0 to 400. Other tests check that copies share every node off the edited path, that an iterator keeps seeing the tree as it was, and that in-place edits keep value semantics.
- **Shapes.** Unit cases for each matching rule and error, and laws on generated values: punch holes (each with the mark of what it replaced) into a random value, then extracting from the original must give back what was punched out, injecting it must rebuild the original, extras added throughout must not change the bindings, injecting without one of the bindings must throw, and the shape must survive being written as text and read back.
- **Edge cases.** NFC vs NFD, integer boundaries and big literals, length-tier edges (6/7/254/255), depth and size limits, a failed decoder staying failed, offsets across compaction, the async adapter, printer spellings, error line and column, and an exit test for the duplicate-literal trap.

The tests were checked for teeth by deliberately breaking the code. Renaming a reject reason fails the `reject` tests. Flipping the "shorter frame sorts after" rule trips the decoder's ordering assertion. Moving the B-tree's split point, or dropping a count update in a rotation, fails the tree tests. Letting a repeated hole bind a second value, or letting a value shorter than the example match, fails the shape tests.

## Limitations and future work

- **No zero-copy views.** Decoding builds full `Value` trees. blnim's `ValueView` equivalent would be a natural `Span` / `RawSpan`-based follow-up once non-escapable stored properties are stable.
- **Lookups compare structurally.** Each comparison walks both values, which is why lookups are several times slower than `Swift.Dictionary`'s hashing. Caching each key's canonical bytes would turn comparisons into `memcmp`, at the cost of memory.
- **Deep values built in code are recursive to process.** Equality, hashing, encoding and printing recurse, so a value nested thousands of levels deep, built programmatically, can overflow the stack. Values that come from the decoder or reader, or go out through the encoder, are capped at the depth limit.
- **The printer is single-line.** blnim's width-aware `pretty` isn't ported.
- **Ideas:** a `#bassline("…")` macro for compile-time-checked literals; a Codable adapter as an explicit dialect; `Transferable` / `UTType` integration for dragging values between apps.
- **Naming.** `Value.Set` hides `Swift.Set` inside any `extension Value`; write `Swift.Set` there. Don't declare a type named `Bassline` in client code, since `Bassline.Value` is how you name this type when a generic parameter called `Value` is in scope.
