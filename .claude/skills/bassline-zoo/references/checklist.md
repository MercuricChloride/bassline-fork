# Implementation checklist

What pillar 1 needs, in the order it's usually built, with the traps blnim, blswift and the JavaScript core each hit, and how to test it. The spec is `data-model.org`; the bassline skill's `references/values.md` is a digest of it.

## Contents

- The value type
- Encoding
- Decoding
- Order and equality
- Text
- The JSON carrier
- Tests

## The value type

- Nine kinds plus a mark bit on every value, nil included. The mark is per value: it never flows into children, and a value built from a marked value's parts doesn't inherit it.
- Integers of any size. Either hold them all (a big integer, or the canonical spelling when it doesn't fit the native type, as blnim does) or refuse what you can't hold. Never truncate or wrap.
- Text is UTF-8 bytes, never normalised. Watch hosts whose strings normalise or compare by canonical equivalence (Swift's `String ==` treats NFC and NFD as equal; blswift keeps text as bytes), or that use UTF-16 (a lone surrogate has no UTF-8 form, so refuse it).
- No booleans or floats in the value space. Keep host conveniences from turning them into values: blswift offers no `Bool` or `Float` literals. In Python, `bool` is a subclass of `int`, so check for `bool` before `int` and refuse it; and since `1`, `True` and `1.0` compare and hash equal, value classes must not subclass `int` or `str`.
- Frames are immutable once built. Dicts and sets keep canonical order by construction (blnim and blswift use B-trees; a sorted array works for small ones).

## Encoding

- Header byte `tag:4 | mark:1 | length:3`. Tags `0x1` nil, `0x2` integer, `0x3` text, `0x4` symbol, `0x5` bytes, `0x6` list, `0x7` record, `0x8` dict, `0x9` set; END is exactly `0xA0`.
- Scalar lengths in the smallest form: 0–6 in the header, 7–254 as `111` plus one byte, 255 and up as `111`, `0xFF`, then four bytes big-endian. The edges 6/7 and 254/255 are where ports break.
- An integer's payload is its canonical decimal spelling: no leading zeros, no `+`, and `-0` is invalid.
- Frames have zero length bits, then constituents, then END. A record always has a head. Dict entries go key, value, key, value, in ascending order of the keys' CE bytes; set members in ascending order of their own.

## Decoding

- Corpus cases are input given in total. A one-shot decode handed a proper prefix of a value reports it incomplete, never with a refusal reason. A resumable decoder, still being given bytes, waits on it and lands nothing.
- Refuse with the corpus's reasons, exactly: `invalid-tag`, `end-with-bits`, `end-at-top`, `length-bits`, `non-minimal-length`, `bad-integer`, `bad-utf8`, `empty-record`, `stranded-key`, `out-of-order`, `duplicate`.
- A depth limit, and a cap on bytes buffered toward one value. The corpus names no reason for these; give your own (blnim says "max frame depth exceeded").
- Check dict and set order on the bytes as they arrive; no need to re-encode.
- When several faults are present, report the first in byte order.
- An explicit stack rather than recursion keeps deep nesting off the call stack and makes feeding one byte at a time as cheap as feeding everything.

## Order and equality

- Two values are equal exactly when their CE bytes are equal. Hash the CE bytes, or something that agrees with them.
- Sorting by CE bytes gives the canonical order directly. A structural comparison has to reproduce it: kind, then mark, then for scalars shorter payloads first and then bytewise, then for frames member by member, with a shorter frame after a longer one it prefixes.
- Caching a value's CE bytes turns comparisons into byte compares, at some memory cost.

## Text

- Follow `data-model.org`'s textual syntax, including the rules that trip people up: set or dict decided by the first entry (`{}` is a set, `{:}` a dict); `:` always its own token; marks touching their value, as a suffix on atoms and a prefix on frames; numbers followed by a delimiter (`1.5`, `42px` and `1-2` are errors); `0x` bytes with an even number of hex digits and optional `_`; `nil` bare is nil and `'nil'` the symbol.
- Escapes in text and quoted symbols: `\\ \n \t \r`, and a backslash before the closing quote.
- Tell refused text from incomplete text. Read as one value, text that runs out inside that value is incomplete (`[1 2`, `!`); text that has begun a second value is refused however it ends (`1 [`, `go !`), and so is text with no value (`""`). `go!!(a)` reads as `go!` and `!(a)`.
- Printing produces the textual syntax, so a value's printed form reads back as the same value.

## The JSON carrier

`corpus.json` is written in the kind-tagged carrier, so a new implementation can bootstrap its tests from it. Each value is an object:

- `"kind"`: one of `nil number text symbol bytes list record dict set`.
- `"mark": true`, present only when the mark is set.
- `"value"`, absent for nil: a JSON number for `number` (wide integers stay bare numbers, so use a parser that keeps them exact); a string for `text` and `symbol`; a `0x`-prefixed hex string for `bytes`; an array of values for `list`, `record` (head first) and `set`; an array of `[key, value]` pairs for `dict`.

## Tests

- The corpus three ways: `corpus.blb` through the decoder, `corpus.bl` through the reader, `corpus.json` through the carrier, all giving the same cases. Re-encoding them must reproduce `corpus.blb` byte for byte. Insert JSON dict and set members shuffled so the collections have to sort them.
- Property tests on random values of every kind, with marks, big integers, long payloads and awkward text: encode and decode, print and read, order agreeing with CE bytes.
- Edge cases: NFC vs NFD, integer boundaries, length-tier edges, depth and size limits, a failed decoder staying failed, feeding one byte at a time.
- Interop: use one capability that only another implementation has from this one, through values over an edge tool.
- Check the tests have teeth: break the code on purpose (rename a reason, flip the shorter-frame rule, move a length-tier edge); the tests must fail.
