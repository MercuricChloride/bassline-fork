# Format doors

Per-format notes for the little compiler: what the trivial first pass reads, and the levers worth having. Every reading here is a choice, not a standard.

## Contents

- Rules for every door
- JSON
- CSV and TSV
- YAML and TOML
- XML and HTML
- Markdown
- SQLite and other tables
- CBOR and MessagePack
- S-expressions and EDN

## Rules for every door

- No booleans or floats become values. A decimal becomes `(dec m e)` (15 × 10^-1 is `(dec 15 -1)`); a binary float is held exactly as a decimal or as its raw bits; `true` and `false` become symbols.
- Document order is kept where the format has it: a list, or records in sequence. Where a reading drops it (a dict), another reading can keep it.

## JSON

- The carrier: the kind-tagged dialect (`lib/json.nim`, `@bassline/core/json`) holds any bassline value and refuses anything else. Use it to move values through JSON-only channels.
- A door for ordinary JSON: objects become dicts with text keys, arrays lists, strings text, integers integers, other numbers `(dec …)`, `true`/`false` symbols, `null` nil.
- Read numbers from the source text, not from the parser's float, or large integers and decimals lose digits.
- Duplicate keys can't be a dict: refuse, or read the object as a list of entries, which also keeps member order. A door can offer both.
- `-0` and `-0.0` have no integer or `(dec …)` form: keep the spelling in a record, or refuse; never read them as `0`. `NaN` and `Infinity` are not JSON: refuse them. A lone surrogate escape has no UTF-8 form: refuse it.
- Levers: keys as symbols; recognising dates, UUIDs or money in text; objects with a `type` field as records under that head.

## CSV and TSV

- First pass: a list of rows, each a list of text cells. Everything is text; nothing is guessed.
- Levers: the first row as a header (each row a dict, or a record under a chosen head); columns read as integers or decimals; empty cells as nil or as silence (the key absent).

## YAML and TOML

- First pass as for JSON. TOML's dates and times become records such as `(date 2026 10 2)`, never text a later reader has to guess at.
- YAML anchors and aliases: expand them (the result is a tree), or keep them as a dialect of named values; a door can offer both.
- YAML tags become record heads.

## XML and HTML

- First pass: each element becomes a record headed by its tag name, then a dict of attributes, then its children in order; text nodes become text.
- Namespaces, comments and processing instructions become records under their own heads, kept rather than dropped.
- Levers: dropping whitespace-only text; attributes as symbols; known vocabularies (an HTML table as a list of rows).

## Markdown

- First pass: blocks in order, each a record (`(heading 2 …)`, `(paragraph …)`, `(list …)`, `(code "nim" "…")`), inline spans nested inside.
- Levers: sections as nested records under their headings; front matter through the YAML door; links as `(link "text" "url")`.

## SQLite and other tables

- First pass: each row a record headed by the table name, columns in declared order. Column types map as for JSON; `REAL` becomes `(dec …)` or raw bits, `BLOB` bytes.
- Levers: rows as dicts keyed by column name; foreign keys followed into nested values.

## CBOR and MessagePack

- First pass: maps become dicts, arrays lists, byte strings bytes, text text, integers integers. Floats as raw bits or `(dec …)`, as above.
- CBOR tags become records headed by the tag number, wrapping the tagged item.

## S-expressions and EDN

- Closest to bassline already. Lists become lists or records (a list starting with a symbol is often a record), keywords symbols, sets sets, maps dicts.
- EDN tagged literals become records headed by the tag.
