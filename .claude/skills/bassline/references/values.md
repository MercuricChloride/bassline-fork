# Values

A working digest of `data-model.org`. The spec is the authority; when the two disagree, the spec wins and this file should be fixed.

## Contents

- The value space
- The canonical encoding
- What a decoder refuses, and what it waits on
- Order and equality
- Textual syntax
- What you can do with values
- Foreign formats

## The value space

A value is an atom or a frame. Values form proper trees; a cycle cannot be expressed and is refused at any boundary.

Atoms, each a distinct kind:

- **nil**: a stated absence, never a default. Three states are kept apart: a stated value, a stated absence (nil), and silence (nothing there at all).
- **integer**: arbitrary precision, signed. Exactly one spelling per integer: `0`, or an optional `-` and digits with no leading zero.
- **text**: well-formed UTF-8, never normalised. NFC and NFD spellings are different values.
- **symbol**: like text, but an identifier rather than a sequence of characters.
- **bytes**: raw bytes.

Frames, each a distinct kind even where one could imitate another:

- **list**: values by position.
- **record**: a head value, then zero or more field values. The head names the topic the fields discuss. A record always has a head.
- **dict**: associations from keys to values, both any value. Unique keys.
- **set**: unique members.

Any value may carry the **mark**, a single bit that shifts its meaning from "something" to "something to do". A marked value never equals its unmarked counterpart. The mark is declared by the sender and is about that utterance only: it does not flow into children, and a value built from a marked value's parts does not inherit it. Acting on a mark is outside the value space.

The grammar is closed. A kind belongs in the model only if a receiver with no vocabulary can do something with it. Dates, rationals, decimals, UUIDs and booleans are arrangements of values, not new kinds.

## The canonical encoding

Every value begins with one header byte:

```
| tag (4 bits) | mark (1 bit) | length (3 bits) |
```

| tag         | kind    | body                              |
| ----------- | ------- | --------------------------------- |
| `0x0`       | invalid | so zeroed memory never decodes    |
| `0x1`       | nil     | none; length bits must be zero    |
| `0x2`       | integer | decimal digits as ASCII           |
| `0x3`       | text    | UTF-8                             |
| `0x4`       | symbol  | UTF-8                             |
| `0x5`       | bytes   | raw bytes                         |
| `0x6`       | list    | values, then END                  |
| `0x7`       | record  | values (head first), then END     |
| `0x8`       | dict    | key, value, key, value…, then END |
| `0x9`       | set     | values, then END                  |
| `0xA`       | END     | only ever the exact byte `0xA0`   |
| `0xB`–`0xF` | invalid |                                   |

Scalars (integer, text, symbol, bytes) state their payload length in the smallest form that fits. Every length has exactly one spelling:

| payload length | form |
| --- | --- |
| 0–6 | in the header's length bits |
| 7–254 | length bits `111`, then one byte |
| 255–2³²−1 | length bits `111`, then `0xFF`, then a 4-byte big-endian length |

Frames carry no length; their length bits are zero. Constituents follow, each self-delimiting, and `0xA0` closes the frame. Dict keys and set members are written in strictly ascending order of their CE bytes.

Examples:

```
nil            10
0              21 30
-7             22 2d 37
"hi"           32 68 69
go!            4a 67 6f            ; symbol, mark bit set, length 2
[]             60 a0
(p 1)          70 41 70 21 31 a0
{a: 1}         80 41 61 21 31 a0
```

## What a decoder refuses, and what it waits on

A decoder refuses, with these reasons (the corpus uses the same names):

| reason               | rule                                             |
| -------------------- | ------------------------------------------------ |
| `invalid-tag`        | tag `0x0` or `0xB`–`0xF`                         |
| `end-with-bits`      | `0xA1`–`0xAF`                                    |
| `end-at-top`         | END outside any frame                            |
| `length-bits`        | nil or a frame header with nonzero length bits   |
| `non-minimal-length` | a longer length form than the length needs       |
| `bad-integer`        | an integer payload that is not canonical decimal |
| `bad-utf8`           | ill-formed UTF-8 in text or a symbol             |
| `empty-record`       | a record with no head                            |
| `stranded-key`       | a dict with a key and no value                   |
| `out-of-order`       | dict keys or set members not ascending           |
| `duplicate`          | a repeated dict key or set member                |

Nesting past the decoder's depth limit is also refused, and every implementation should have a depth limit. A cap on how many bytes a decoder will buffer toward one value is good practice (blnim has one), though the spec doesn't ask for it.

The corpus's cases are input given in total. Given in total, input that runs out inside a value is bad, but for running out rather than for breaking a rule: it is reported as incomplete, never with one of the reasons above (`data-model.org` lists it among the rejections). A decoder still being given bytes waits on it instead, yielding nothing and resuming when more arrive. The corpus's `starved` cases pin this down, and keeping them apart from refusals is what lets a decoder read values as their bytes arrive.

## Order and equality

Two values are equal exactly when their CE bytes are equal.

Values are ordered by their CE bytes. Written out structurally, for an in-memory reading: by kind, then mark, then for scalars shorter payloads first and then bytewise, then for frames member by member, with a shorter frame sorting after a longer one that it prefixes (its END, `0xA0`, is higher than any header a longer frame would have there). The simplest correct implementation sorts dict keys and set members by their encoded bytes.

## Textual syntax

The textual syntax is a human form that compiles to values. It is not an encoding and carries no identity of its own.

```
nil                       nil ('nil' is the symbol)
42  -7  1_000_000         integers; _ only between digits; no +, no decimals
"text"                    text; escapes \\ \n \t \r and \"
sym  'has space'  'a:b'   symbols, bare or quoted (\' inside quotes)
0xdead_beef  0x           bytes; even hex count, either case
[a b c]                   list
(head a b)                record
{a b}  {}                 set, empty set
{k: v  k2: v2}  {:}       dict, empty dict
go!  5!  "hi"!  0xab!     marked atoms: ! as a suffix
!(do x)  ![a]  !{k: v}    marked frames: ! as a prefix
; comment to end of line
```

Rules that trip people up:

- The first element inside braces decides set or dict. A `:` after it makes a dict, and every element must then be an entry.
- `:` is always its own token, so `foo:bar` reads as `foo : bar`.
- A mark must touch its value, and a trailing mark must be followed by a delimiter: `a!b` is an error, not two values. A repeated mark on a frame (`!!(f)`), a leading mark on an atom (`!go`) and a trailing mark on a frame (`(f)!`) are errors. After a marked atom, a second `!` starts a new marked frame: `go!!(a)` reads as `go!` and `!(a)`.
- A number must be followed by a delimiter: `1-2`, `42px` and `1.5` are errors. `-` and `->` are symbols; `-5` is a number. `0xff` is one byte, not 255.
- Read as one value, text that runs out inside that value is incomplete (`[1 2`, or `!`, a mark waiting for its frame). Text that has begun a second value can never be one value and is refused however it ends (`1 [`, `go !`); so is text holding no value. A reader still being given text, someone typing, waits instead.

## What you can do with values

With no vocabulary at all:

- **Identity and integrity.** Equality, hashing, deduplication, digests and signatures all work on CE bytes. blnim's `crypto/` signs and digests values this way. A signed value is a dialect; trust is a local reading of what it carries.
- **Order.** Any set of values sorts the same way everywhere.
- **Concatenation.** Values written one after another as CE (a `.blb`) need no other framing; a resumable decoder reads them as bytes arrive.
- **Prefix queries.** CE spells a record's head first, so the encoding of `(person)` with its frame left open is a byte prefix of every `(person …)`. blnim's `prefixes` says whether one value is what another's encoding yields when stopped early, and `frameKey` is the byte prefix that selects them. A prefix narrows; equality or a shape decides, since `(signed [1 2])` is also a prefix of `(signed [1 2 3] …)`.
- **Shapes.** A shape is a value with a logical template in it. Matching finds what fills its holes in a given value; injecting fills them. A hole can have several fillings, which is why shape matching belongs with search. How shapes are written is likely to change.
- **Walking.** Map, fold and walk structure without knowing what it means.
- **Text.** Print any value readably and read it back.

## Foreign formats

Two different jobs:

- A **carrier** holds bassline values in another format and refuses anything that isn't one. The JSON dialect in blnim (`lib/json.nim`) and JavaScript (`@bassline/core/json`) is a carrier: each value becomes a kind-tagged object, `{"kind": …, "mark": true, "value": …}` with the mark present only when set.
- A **door** reads a foreign document into values, holding what it says exactly and refusing only what values cannot hold; the `bassline-zoo` skill builds them.

Neither is canonical: the only identity a value has is its CE bytes.
