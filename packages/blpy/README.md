# blpy

A Python implementation of the [bassline data model](../../data-model.org): values that feel like Python objects, the canonical encoding (an encoder and a resumable decoder), the textual syntax (a printer and a resumable reader), readings between Python objects and values, the kind-tagged JSON carrier, the first operations on values (walk, fold, transform, prefixes), searches and streams, sends and edge tools over byte channels, and format doors with `bl magic`, a converter between JSON, CSV, TSV, TOML, XML, YAML, the textual syntax and CE.

It passes every case in the shared corpus (`../../corpus`): all 143, under all seven heads, with the exact reason for each rejected input, read three ways (`corpus.bl` through the reader, `corpus.blb` through the decoder, `corpus.json` through the carrier).

```python
from bassline import bl, sym, rec, encode, decode

person = bl('(person {name: "Ada" born: 1815})')
person == rec(sym.person, {sym.name: "Ada", sym.born: 1815})   # True
encode(person)          # b'pFperson\x80Dborn$1815Dname3Ada\xa0\xa0'
decode(encode(person)) == person                               # True: identity is the bytes
print(person)           # (person {born: 1815 name: "Ada"})
person[1][sym.name]     # bl('"Ada"')
```

- [Requirements](#requirements)
- [Usage](#usage)
- [Search, sends and the edge](#search-sends-and-the-edge)
- [Format doors and bl magic](#format-doors-and-bl-magic)
- [Design notes](#design-notes)
- [Compared with blnim and blswift](#compared-with-blnim-and-blswift)
- [Testing](#testing)
- [Not built yet](#not-built-yet)

## Requirements

- Python 3.11 or later (tested on 3.13 and 3.14)
- No runtime dependencies. The YAML door is there only when [PyYAML](https://pyyaml.org) imports (`pip install 'blpy[yaml]'`); everything else is the standard library.

The package uses a `src` layout and the standard setuptools backend. Nothing needs installing to use it from this repository or to run its tests; `pip install blpy` installs it as `bassline`, with `bl-magic` and the `bl-search-*` tools as console scripts. To use the tools from this checkout without installing, put `bin/` on your PATH:

```sh
export PATH="$PWD/packages/blpy/bin:$PATH"   # from the repository root
bl-magic --formats
bl magic data.json -t text                     # through blcli's bl, which runs bl-magic from PATH
```

## Usage

### Building values

```python
from bassline import (bl, sym, rec, mark, nil, to_value,
                      Integer, Text, Symbol, Bytes, List, Record, Dict, Set)

bl("[1 two \"three\" 0x04 nil]")          # read the textual syntax: the shortest way in
to_value([1, "two", b"\x03", None])        # [1 "two" 0x03 nil]: the default reading of Python objects

sym.go                    # go          (sym("has space") for any name)
rec(sym.point, 1, 2)      # (point 1 2) (Record(head, *fields) is the same)
mark(rec(sym.sign, 42))   # !(sign 42)
Integer(10**40)           # integers of any size
Text("caf\N{LATIN SMALL LETTER E WITH ACUTE}")
Bytes(b"\xde\xad")        # 0xdead
List([1, [2]])            # [1 [2]]
Dict({sym.a: 1, 2: "b"})  # {2: "b" a: 1}, kept in canonical order (integers before symbols)
Set([3, 1, 2])            # {1 2 3}
nil                       # nil
```

Constructors read their members with the default reading, so Python ints, strings, bytes, lists, dicts, sets and `None` can be mixed with values. A `bool` or a `float` is refused everywhere (`NotHeld`, which is both a `TypeError` and a `ValueError`): booleans and non-integer numbers are vocabulary, not values.

The mark is a flag on every value: `v.mark` reads it, `v.marked()` and `v.unmarked()` give the value with it set or cleared (sharing the payload), and `mark(x)` / `unmark(x)` do the same for anything readable.

### Reading values

Values are Python collections and atoms with a `.value`:

```python
v = bl('(person {name: "Ada" tags: {math poetry}} born!)')
v.head                  # bl('person')
v.fields                # a tuple of the fields
v[1][sym.name].value    # 'Ada'
sym.math in v[1][sym.tags]   # True
len(v), list(v)         # a record is a sequence, head first, like its encoding
v[2].mark               # True
```

Pattern matching works on every kind:

```python
match value:
    case Record(Symbol("point"), (Integer(x), Integer(y))):
        ...
    case Record(Symbol("sign"), (payload,), mark=True):
        ...
    case List([first, *rest]):
        ...
    case Set(members):              # a tuple, in canonical order
        ...
    case {sym.name: Text(name)}:    # a Dict is a mapping
        ...
    case Nil():
        ...
```

### Dicts, sets, and silence

```python
d = bl('{name: "Ada" note: nil}')
d[sym.name]            # bl('"Ada"')
d["name"]              # KeyError: a Python str reads as text, and the key is a symbol
d.get(sym.note)        # bl('nil'): a stated absence
d.get(sym.missing)     # None: silence, which is not nil
d | {sym.born: 1815}   # a new dict; values never change
d.without(sym.note)

s = Set([1, 2, 3])
2 in s, s | {4}, s & {2, 9}, s.issubset([1, 2, 3, 4])
```

Iteration, printing and encoding all follow canonical order. `Set(iterable)` drops repeats the way `set()` does; the reader and decoder refuse repeats, and `Dict` refuses a key given twice rather than picking one.

### Equality, hashing and order

Two values are equal exactly when their canonical encodings are equal, and they hash and sort by those bytes. So values work as `dict` keys and in Python sets, and `sorted()` gives canonical order:

```python
sorted(to_value([10, 9, -1, 1]))   # [bl('1'), bl('9'), bl('-1'), bl('10')]: shortest spelling first
Integer(1) == 1                     # False: a value never equals a Python object
Text("\N{LATIN SMALL LETTER E WITH ACUTE}") == Text("e\N{COMBINING ACUTE ACCENT}")   # False: never normalised
```

See [order is canonical order](#order-is-canonical-order) for the trap this sets.

### The canonical encoding

```python
from bassline import encode, encode_all, decode, decode_all, Decoder, iterdecode

encode(v)                    # bytes (also v.ce, cached)
decode(b)                    # exactly one value
decode_all(b)                # every value in a bare concatenation (a .blb)
```

A `Decoder` takes bytes however they arrive and hands over each value as soon as its last byte is in. Bytes that are wrong raise `DecodeError`; bytes that are only the start of a value wait:

```python
d = Decoder(max_depth=64, max_value_bytes=100 * 2**20)
for chunk in chunks:
    for value in d.feed(chunk):     # feed() returns the decoder; iterate it
        handle(value)
for value in d.finish():            # raises Incomplete if input stopped inside a value
    handle(value)

# or, reading a file descriptor unbuffered:
for value in iterdecode(iter(lambda: os.read(fd, 65536), b"")):
    handle(value)
```

`DecodeError` has a `reason` (a `Reason`, a string enum) and the input `offset` of the byte that broke the rule. The reasons are the corpus's names, plus three of this implementation's own:

```
invalid-tag  end-with-bits  end-at-top  length-bits  non-minimal-length
bad-integer  bad-utf8  empty-record  stranded-key  out-of-order  duplicate
too-deep        a frame opened past max_depth
too-large       a value whose bytes would pass max_value_bytes
trailing-bytes  decode() wanted one value and well-formed values followed
```

A decoder that has refused raises the same error forever. `decode()` and `decode_all()` raise `Incomplete` when the input stops inside a value; `decode(b"")` is `Incomplete` too, while `decode_all(b"")` is `[]`.

Refusals share a base, `Refused` (`DecodeError`, `ReadError` and `NotHeld` are all refusals). `Incomplete` sits beside it, not under it, so `except Refused` never catches input that only needs more bytes. Both are `BasslineError`s, which are `ValueError`s.

### Text

```python
from bassline import bl, read, read_all, Reader, iter_read, pretty

read('(f go! !(g))')                 # exactly one value (bl() is the same, for literals)
read_all('; a document\n1 2 [3]')    # [1, 2, [3]]
str(v)                               # the textual syntax on one line
pretty(v, width=60)                  # laid out within a width where it can be
repr(v)                              # bl('...'), which evaluates back to v
```

`ReadError` (refused) and `Incomplete` (the text stopped where more could still make it valid) are different exceptions, so a REPL can keep reading on `Incomplete`. Both carry `offset` (in characters), `line` and `column`. `read` takes the text as all there is: text that stops inside its value is incomplete, while once the value is read, anything after it but whitespace and comments is refused, so `1 2`, `1 [` and `go !` are refused, and so is text with no value.

A `Reader` takes text (or UTF-8 bytes, split anywhere) however it arrives:

```python
r = Reader()
for chunk in chunks:
    for value in r.feed(chunk):
        handle(value)
for value in r.finish():   # the last atom completes at end of input
    handle(value)
```

### Readings between Python and values

A reading turns Python objects into values or values into Python objects. Each is a small object holding its own rules; there is no registry everything must go through.

```python
from bassline import to_value, symbolic, symbol_keys, to_python, plain

to_value({"name": "Ada", "tags": ["x"]})     # {"name": "Ada" "tags": ["x"]}   the default
symbol_keys({"name": "Ada", "tags": ["x"]})  # {name: "Ada" tags: ["x"]}       str keys as symbols
symbolic(["go", "stop"])                     # [go stop]                       every str a symbol

to_python(bl('{"a": [1 0x00 nil] "s": {1 2}}'))   # {'a': [1, b'\x00', None], 's': frozenset({1, 2})}
to_python(bl("go"))                               # NotHeld: a str would lose that it is a symbol
plain(bl("[go {a: b}]"))                          # ['go', {'a': 'b'}]: symbols as str, by name
```

Make a sibling with `.but(rules)`. A rule takes the object and a `read` callable for its members:

```python
from decimal import Decimal

def dec(x, read):
    if not x.is_finite():
        raise NotHeld(f"{x} has no (dec m e) form")
    sign, digits, exponent = x.as_tuple()
    m = int("".join(map(str, digits)))
    if sign and not m:
        raise NotHeld(f"{x} has no (dec m e) form: its sign would be lost")
    return rec(sym.dec, -m if sign else m, exponent)

decimals = to_value.but({Decimal: dec})
decimals([Decimal("1.5")])     # [(dec 15 -1)]
decimals([Decimal("1.50")])    # [(dec 150 -2)]: the spelling's precision is kept
decimals([Decimal("-0")])      # NotHeld, as are NaN and Infinity
```

A Python type can declare its own default reading in with `__bassline__`:

```python
@dataclass
class Point:
    x: int
    y: int
    def __bassline__(self):
        return rec(sym.point, self.x, self.y)

to_value([Point(1, 2)])        # [(point 1 2)]
```

### The JSON carrier

```python
from bassline import carrier

carrier.to_json(v)                 # {"kind": "record", "value": [...]}
carrier.to_json(v, indent=2)
carrier.from_json(text)
carrier.to_carrier(v)              # the same as a dict/list tree
carrier.from_carrier(tree)
carrier.load_tree(text)            # parse JSON the way the carrier needs it (exact integers)
```

The carrier holds any value and refuses anything that isn't one. It is not a door for ordinary JSON.

### Working with values

```python
from bassline import walk, fold, transform, prefixes, frame_key, under

list(walk(v))                          # every value, v first, depth first
fold(v, lambda x, results: 1 + sum(results))       # bottom up: here, a count
transform(v, lambda x: Integer(x.value + 1, mark=x.mark) if x.kind == Kind.INTEGER else x)
prefixes(bl("(signed [1 2])"), bl("(signed [1 2 3] x)"))   # True
frame_key(bl("(person)"))              # the byte prefix selecting every (person …)
list(under(bl("(person)"), facts))     # the facts it prefixes, picked by their bytes
```

Frames also have a shallow `.map(fn)` over their members, keeping their mark.

## Search, sends and the edge

### Searches and streams

A **search** is what you ask: any callable that takes a query and hands back a stream. A **stream** is what it hands back: a Python iterator, pulled with `next` or a `for` loop. A generator function is the laziest search; a search can as easily do its work when asked and hand back a stream over what it found.

```python
from bassline import alt, alt_from, feed, first, take, fan, through

def steps(term):                    # a search: calling it runs nothing yet
    while (term := reduce_once(term)) is not None:
        yield term                  # one answer per pull

first(steps(t))                     # one step, then stop
take(steps(t), 1000)                # up to 1000, pulling no more

alt(endless, finite)                # fair turns, dropping streams that end
alt_from(s(v) for s in experts(v))  # fair turns over a stream of streams, admitting each on its turn
feed(values, search)                # each value asked of search, the streams alternated fairly
fan(s1, s2)(q)                      # a search asking both, alternating their streams
through(header, numbers)(table)     # a search feeding each answer of one to the next
```

Python already has the rest, so this package doesn't wrap them: `itertools.chain` is cat (`chain.from_iterable` for a stream of streams, one after another), `map` and `filter` (or a generator expression) map and filter, and `itertools.islice` takes lazily where `take` gives a list.

[`bassline.doors.readings`](#guessing-and-readings) is a search that works when asked: it asks every door how sure it is and ranks them then, and its stream reads the document one door at a time, only as answers are pulled.

`Heard` keeps what has been heard, each value once in arrival order: `heard.add` is a send, and iterating it or `heard.under(prefix)` are searches over what has arrived by each pull, so a stream over it keeps up with an edge tool feeding it from another thread.

### Sends and the edge

A **send** is a callable over a value that may answer `True` or `False`, whether it was understood enough to act on; for a send that carries bytes, whether they were accepted for carriage. It never answers what happened, and answering nothing (`None`) is allowed.

Edge tools turn byte channels into values and sends, and nothing about the channel goes further:

```python
from bassline import read_ce, ce_writer, pipe, Heard, bl

for v in read_ce(0):                 # stdin (an fd, path or binary file), os.read: each value as it lands
    ...                              # raises Incomplete / DecodeError after the values before it

out = ce_writer(1)                   # a send writing each value's CE to stdout, whole and flushed
out(bl("(hello)"))                   # True; False once the reader has gone (a closed pipe)

heard = Heard()
with pipe(["bl-search-numbers"], into=heard.add) as numbers:   # a command, spoken to in values
    to_numbers = numbers.send        # a send into its stdin: all program logic needs
    to_numbers(bl('["1.50" "x"]'))
# heard now holds [(dec 150 -2) "x"]: what its stdout carried, fed to a local send
```

`pipe` returns the edge's handle, for whoever runs the command; program logic gets only its `send`, which knows nothing of the process. The handle reads the command's stdout on a thread of its own and hands each value to `into` as it completes; closing (`close()`, or leaving the `with`) stops sending, lets the command finish what it has to say, and returns its exit status, waiting as long as that takes unless given a timeout. If the command's output ended partway through a value, `failure` says so; if `into` raised, `close()` raises it.

## Format doors and bl magic

### Doors

Each door is a module in `bassline.doors` with the same few functions:

```python
from bassline import doors

doors.json.loads('{"price": 1.50, "n": 123456789012345678901234567890}')
#   {"n": 123456789012345678901234567890 "price": (dec 150 -2)}
doors.json.read(data)                     # a stream of the document's values
doors.json.read(data, "json-entries")     # another reading of the same door
doors.csv.loads("a,b\n1,2\n")             # [["a" "b"] ["1" "2"]]
doors.toml.dumps(value)                   # one value, written
send = doors.xml.writer(file)             # a send writing each value it is handed
doors.yaml.sure(data)                     # 0-100: how sure the door is these bytes are YAML
```

| door | first pass | writer |
| --- | --- | --- |
| `ce` | a bare concatenation of CE, refusals named by corpus reason | each value's CE |
| `text` | the textual syntax, a document of values | each value laid out in 80 columns |
| `json` | objects dicts with text keys, arrays lists, numbers from their spelling (integers exact, others `(dec m e)`), `true`/`false` symbols, `null` nil; several texts in a row are several values | indented (`json`) or a line each (`jsonl`) |
| `carrier` | the kind-tagged carrier: any value, exactly | a line of carrier JSON each |
| `csv`, `tsv` | a list of rows, each a list of text cells; nothing guessed | a table, dict rows under one header |
| `toml` | tables dicts, floats `(dec m e)`, dates and times records | minimal: a dict, nested dicts as `[tables]` |
| `xml` | an element is `(tag {attributes} children…)`, one text per run of text; comments, processing instructions, the doctype and its declarations, and entity references it can't expand are records of their own | the same arrangement back |
| `yaml` | as JSON, with tags as record heads, anchors expanded; what YAML 1.1 and 1.2 read differently (`no`, `010`, `2002-12-14`) stays the text written (only with PyYAML) | a document each, records as tagged sequences |

What the first passes refuse, because values can't hold it: JSON's `NaN` and `Infinity`, a lone surrogate escape, bytes that aren't UTF-8, an object or mapping that gives a key twice (by the `json` reading; `json-entries` keeps it), malformed documents of every kind. A negative zero has no integer or `dec` form, so it is kept as `(number "-0")`, as are TOML's and YAML's infinities and NaNs. Writing out is lossy: marks, and the difference between a symbol and text, are dropped, and a writer refuses only what its format can't hold at all (TOML has no nil and 64-bit integers; an XML document is elements; no format here can hold two keys it would spell alike, such as `{1: a "1": b}` in JSON).

### Levers

Levers are searches over the values, applied in order between reading and writing. Each answers the readings it makes of a value (usually one) and leaves alone what it doesn't apply to; whoever consumes a lever that answers several takes them in order.

| lever | what it rereads |
| --- | --- |
| `keys-as-symbols` | every text dict key as a symbol |
| `numbers` | every text that spells an integer or decimal as one (`"007"`, `"+5"`, `"-0"` stay text; dict keys too) |
| `header[=HEAD]` | a table's first row as its keys: each row a dict, or `(HEAD {…})` |
| `drop-keys=K1,K2` | those keys (text or symbol) out of every dict |
| `typed-records=FIELD` | every dict with that key as a record headed by its value: `{"type": "person" …}` is `(person {…})` |
| `entries` | every dict as a list of `[key value]` |
| `drop-whitespace` | whitespace-only text beside records, out of records' fields (indentation between XML elements); a record's only text stays |

```python
from bassline import levers, through
rows = through(levers.header, levers.numbers)(table)     # a stream
levers.lever("drop-keys=internal,debug")                 # a lever from its command-line spelling
levers.drop_keys(bl("1"), "debug")                       # keys are values; a str is a spelling
```

A lever's argument is a value, read as the textual syntax: `header=row` heads each row with the symbol `row`, `header='"my row"'` with that text, `drop-keys=1` drops the integer key 1, `drop-keys='"a,b"'` the one key `"a,b"`, and a bare `drop-keys=a,b` (a symbol with commas, as a shell spells several names) or `drop-keys='[a b]'` both `a` and `b`. `drop-keys` and `typed-records` match a text or symbol key by its spelling and any other key by equality.

### bl magic

`bl-magic` follows the toolkit's [`bl magic`](../../.claude/skills/bassline-zoo/references/cli.md) exactly:

```sh
bl magic data.json                     # JSON in, CE on stdout
bl magic data.json out.toml            # convert through values
cat notes.csv | bl magic               # sniff stdin, CE on stdout
bl magic - out.csv                     # CE on stdin, CSV file out
bl magic data.json -t text             # the textual syntax, for people
bl magic in.csv out.json -l header -l numbers    # levers, in order
bl magic -l keys-as-symbols            # CE in, CE out: one lever as a filter
bl magic --readings notes.txt -t text  # every plausible reading, as (reading FMT value)
bl magic --formats                     # what it reads and writes
bl magic --levers                      # and which levers it has
```

The input format is `-f FMT`, else the input's extension, else a guess from the content; the output format is `-t FMT`, else the output's extension, else CE. What it guessed it says on stderr (`-- reading notes.txt as csv (guessed from content)`). `-f` takes a format (`json`, meaning its readings in order) or one reading (`json-entries`), and is taken at its word, with `--readings` too; `-t` takes a writer (`json`, `jsonl`, …).

A lever this magic doesn't have runs as `bl-search-NAME` from PATH, as `bl search NAME` would run it, from whichever implementation provides it: the values go to its stdin as CE and its answers carry on to the next lever. `--levers` lists those too.

### bl search

Every lever is also `bl-search-NAME`, so blcli's `bl search` runs and lists it with the toolkit's own searches:

```sh
bl magic people.csv -l header | bl search numbers | bl cat
bl serve | bl search keys-as-symbols | bl cat          # keeps answering as values land
bl search drop-keys internal,debug < records.blb
bl search                                              # lists them, a line of --help each
```

Each reads CE on stdin and writes each answer as CE as soon as it has it; `-n N` takes N answers. A lever's argument is its query, a value read by recognition as blcli reads one: a file if one exists (CE, else the textual syntax), else the argument as the textual syntax, else as CE. So `bl search header 10` heads rows with the integer 10 in either implementation.

## Design notes

### A class per kind, and none of them an `int` or a `str`

There are nine classes under `Value`, so `isinstance` and `match` tell kinds apart. None subclasses `int` or `str`: in Python `1 == True == 1.0` and they hash alike, so an `Integer` that was an `int` would equal `True` and collide with it as a key. A value never equals a Python object (`Integer(1) == 1` is false), because equality is CE equality and hashing is CE hashing; an `__eq__` that also accepted Python objects would need hashes to agree with Python's, which CE hashing can't. Pattern matching covers the convenience: `case Integer(1)`.

`Symbol` and `Text` share a private base rather than one subclassing the other, so a symbol is never `isinstance` of `Text`.

### Identity is the bytes, cached

Every value computes its canonical encoding once, on first need, and keeps it (`v.ce`). `==`, `hash` and `<` compare those bytes, which makes ordering trivially agree with the spec and turns comparisons into `bytes` comparisons. The cost is memory: a value holds its payload and its encoding. Text and symbols encode at construction (validating UTF-8 needs the bytes anyway), and the decoder hands each scalar, and each set member or dict key, the bytes it already has.

Values are immutable: `__setattr__` refuses, frames hold tuples or a private `dict`, and every operation builds a new value. `copy` returns the value itself, and a value pickles as its encoding.

### Order is canonical order

`<` on values is canonical order, so `sorted()` gives the order dicts and sets keep. It is not numeric order: integers sort by the length of their spelling first, so `max(to_value([-100, 5]))` is `-100`. Compare `.value`s for arithmetic.

For the same reason a `Set`'s `<` is canonical order rather than "proper subset" as on Python sets; use `issubset` and `issuperset`.

### Integers

An `Integer` holds a Python `int`, or, when it came from bytes, only its encoding until `.value` is first read. Python 3.11 limits `int`↔`str` conversion to 4300 digits by default; this package converts longer integers itself by splitting, so integers of any size encode, decode, print, read and travel through the carrier without touching the interpreter-wide setting.

### Text is a Python string that has a UTF-8 form

Python strings compare by code point, so there is no normalisation to defend against, unlike Swift. What Python strings can hold that UTF-8 can't is a lone surrogate (from `surrogateescape`, or a JSON `\ud800`-style escape); `Text`, `Symbol` and every reading refuse one.

### Frames as Python collections

- `List` is a sequence. A slice is a new, unmarked list: a value built from a marked value's parts doesn't inherit its mark.
- `Record` is a sequence too, head first like its encoding, with `.head` and `.fields`. A slice is a plain tuple, since a slice of a record need not keep its head. `Record()` with no head is a `TypeError`.
- `Dict` is a mapping and `Set` is a set. Both keep a Python `dict` built in canonical order, so iteration is canonical by construction and lookups are hashed. Functional updates (`|`, `without`) rebuild and re-sort.
- A Python object used as a key, member or probe (`d["name"]`, `1 in s`) is read with the default reading first. That is why `d["name"]` looks up text and `d[sym.name]` a symbol. A probe that can't be read at all (`1.5 in s`) raises `NotHeld`, as Python raises `TypeError` for an unhashable probe.
- Atoms have no `__bool__`, so every atom is truthy, `nil` included: nil is a stated absence, and `if v:` should not confuse it with silence. Frames are truthy when non-empty, as Python collections are.

### `str()` is the textual syntax

`str(Text("hi"))` is `"hi"` with its quotes, as the task of `str` here is to show a value; `.value` is the Python string. `repr` is `bl('…')`, which evaluates back to an equal value.

### Readings, not a registry

`to_value`, `symbolic`, `symbol_keys`, `to_python` and `plain` are each a small object holding its own rules, and `.but()` makes another from any of them. Rules are found along the Python type's MRO, so a rule for `dict` covers `OrderedDict`, and `Mapping`, `Set` and `Sequence` rules catch other collections. `__bassline__` lets a type declare its own default reading in; a reading's own rule for that type comes first. This is local dispatch inside one reading, not a table everything passes through: nothing stops two readings disagreeing about the same type.

Reading in refuses what values can't hold: `bool`, `float`, `complex`, lone surrogates, cycles (values are trees), distinct Python members that read as one value. Reading out refuses what Python can't hold: marks, symbols and records have no Python form that keeps what they are, so `to_python` refuses them, and `plain` gives up symbols' difference from text only because its name says so; it still refuses a dict or set where that would merge two entries into one (`{a: 1 "a": 2}`). Lists inside a key or set member come out as tuples, since Python needs those hashable; a dict there is refused.

### The decoder

- **An iterator, fed.** `feed()` decodes eagerly into a queue and returns the decoder; iterating it yields the values that completed and then raises the refusal, if any. Values that completed before a fault are never lost, and the fault surfaces in byte order.
- **An explicit stack, no recursion.** Feeding one byte at a time does the same work as feeding everything; a scalar arriving in pieces is checked from where the last piece stopped, so a long payload in small chunks stays linear.
- **Where a fault is reported.** Each rule is judged at the first byte that can break it, and the decoder refuses at the first byte that breaks any rule:

  | rule | the byte |
  | --- | --- |
  | `invalid-tag`, `end-with-bits`, `end-at-top`, `length-bits`, `too-deep` | the header (or END) |
  | `non-minimal-length` | the one-byte length, or the last of the four |
  | `bad-integer`, `bad-utf8` | the first payload byte no well-formed payload of the declared length could have there |
  | `empty-record`, `stranded-key` | the END |
  | `out-of-order` | the first byte at which a member or key falls below its predecessor |
  | `duplicate` | the last byte of the repeat |
  | `too-large` | the byte that shows the value passing the cap |

  At one byte, a value's own rules come before its order against its predecessor, and order before duplication. Order is compared on the bytes as they arrive, not when a member completes, so `90 41 62 37 61` (a set whose second member is text, which sorts before the symbol before it) is refused at byte 3 even though the input stops inside that member. The verdict (the values, the reason and the offset) is the same however the input is chunked; the tests check that on thousands of corrupted inputs, and check that every refusal's offset really is the first byte that breaks: feeding the bytes before it is still acceptable.

- **Limits.** `max_depth` (default 64, as in blnim and blswift) and `max_value_bytes` (default 100 MiB) are per decoder. A scalar's declared length counts against the cap as soon as it is read, so a header promising 4 GiB is refused before any payload arrives. One-shot `decode` and `decode_all` raise the cap to at least the input's length, since the caller already holds those bytes.
- **Empty input.** `decode(b"")` raises `Incomplete`: no bytes is a proper prefix of every value. `decode_all(b"")` is `[]`.

### The reader

- **Resumable, with the same explicit-stack shape.** A frame is complete at its closing bracket. An atom is complete at the delimiter after it, since `12` could still become `123` and `go!` could still turn out to be the error `go!b`; at end of input, `finish()` completes it. An atom arriving in pieces collects them itself, so the buffer can be dropped as it is consumed and long tokens in small chunks stay linear.
- **A mark touching a closed frame.** `(f)!` is refused, but a reader that handed over `(f)` at its `)` refuses the `!` when it arrives, after the fact, as the decoder refuses a stray END after a value. `go!!(a)` is two values, `go!` and `!(a)`.
- **Refused versus incomplete.** `[1 2` and `!` are incomplete; `[1 2)` is refused. `read`, which wants one value from text that is all there is, refuses `1 2`, and `1 [` and `go !` as well, since a second value has begun and no more text could make them one; a refusal in what follows is reported as itself, so `(f)!` still says the frame is marked behind. A document, or a `Reader` still being given text, waits on `1 [` and `go !` instead. `read("")`, and text of only whitespace and comments, is refused for holding no value, unlike `decode(b"")`, which is incomplete; `read_all("")` is `[]`.
- **Escapes** are `\\ \n \t \r` and a backslash before the closing quote (`\"` in text, `\'` in a quoted symbol). Any other escape, including the other quote, is refused at its backslash as soon as it arrives, without waiting for a closing quote that couldn't help.
- **Positions** count characters (code points). Bytes fed to a reader are decoded as UTF-8 incrementally; a sequence split across chunks waits, and malformed UTF-8 is refused.
- **The printer** quotes a symbol when it is empty, `nil`, number-like, or contains a delimiter, a control character or whitespace (including non-ASCII whitespace such as a no-break space, which blnim prints bare). Printing and reading are inverses, checked on random values; `pretty` is a port of blnim's width-aware layout.

### The JSON carrier

Integers of any width are written and read exactly: writing uses its own small emitter (Python's `json` can't write an integer past the digit limit), and reading passes `parse_int` so wide integers never become floats. Floats, `NaN`, `Infinity`, `-0`, an unknown or repeated object key, a repeated dict key or set member, and a lone surrogate are refused. Dict entries and set members may arrive in any order; `"mark": false` and either case of hex digits are accepted. Like the JavaScript carrier, it is stricter than blnim's in refusing unknown keys.

### Recursion

The decoder, reader, printer, encoder, equality, hashing, the carrier's own conversions and every operation in `ops` use explicit stacks, so a value nested 20,000 deep (built in code; the decoder and reader refuse past their `max_depth`) round-trips without touching the call stack. The exceptions: readings between Python and values recurse, as `json` does; `pretty` lays out the first 200 levels and prints anything deeper on one line; and `carrier.from_json` parses with Python's `json`, which recurses, so a carrier document nested past what it can follow is refused with `NotHeld` (`from_carrier` on an already-parsed tree has no such limit).

### Searches are callables, streams are iterators

Python makes it easy to blur the two, since a generator function is both a callable and the maker of an iterator. The names keep them apart: everything that takes a query and answers a stream is a search (`levers.numbers`, `doors.json.read`, `Heard.under`, `fan(...)`, `through(...)`), and everything you pull is a stream. Streams are synchronous iterators; nothing here needs `async for` yet.

`alt_from` gives its source one turn in each round, beside the streams it has already given: one newcomer, then one answer from each live stream, the newcomer included. So an endless supply of streams can't hold up the first ones' answers, and a stream learned late joins on its turn. It can't tell a source that will never give another stream from one that is slow: a source endlessly giving empty streams loops without answering, as it must.

### Fair inside a value, in order across values

`feed` alternates fairly, which is right for local searches but wrong at the edge: on a live pipe, pulling the next input value blocks until it arrives, holding back answers already in hand. So the edge filters (`bl-search-*`, `bl magic` on CE) drain each value's answers before reading the next value (`chain.from_iterable(map(search, values))`), and levers chained on one value are fed fairly with `through`. A search that answers endlessly about one value would hold back the values after it; none of the levers here does.

### Sends answer True, False, or nothing

The edge's sends answer `False` once whoever reads the channel has gone, and keep answering `False`; the tools stop writing on an explicit `False` and exit 0. A send that answers nothing (`None`, say `list.append`) is not taken as refusing: a send may stay silent.

A writer refusing a value its format can't hold raises `NotHeld`, the same refusal readings raise, rather than answering `False`: `False` would say the value wasn't carried, not why.

### The edge reads with os.read

`chunks` reads a file descriptor with `os.read`, which hands over whatever has arrived, so each value is decoded and acted on as soon as its last byte lands; Python's buffered `read(n)` would wait to fill its buffer. A buffered file object is read with `read1`, which hands over what it has already read ahead and then reads at most once, so it is as live and loses nothing. A write to a non-blocking channel waits until the channel can take more. `ce_writer(1)` writes to the descriptor itself, unbuffered, so nothing is left in a buffer when downstream goes away, and Python's "Exception ignored … BrokenPipeError" at exit never appears. `Pipe` reads the command's output on its own thread, since a synchronous program can't otherwise listen and speak at once; `into` is called from that thread. The handle (process id, `close`, `failure`) stays with whoever runs the command; `send` is a plain closure, so code handed it holds a place to speak and nothing else.

### What the doors choose

- **Numbers from their spelling.** JSON numbers go through `parse_int`/`parse_float` hooks that see the source text, never a float: an integer of any length is exact (past Python's 4300-digit limit), and `1.50` is `(dec 150 -2)`, keeping the precision the spelling states. The writer spells `(dec m e)` back so it reads as the same `dec` (`1.50`, `1e3`, `15e0`), switching to an exponent when a point form would be long. TOML and YAML floats are read the same way from their spellings (TOML's underscores and a leading `+` mean nothing in TOML and are dropped).
- **Negative zero** has no integer or `dec` form; dropping its sign would lose what the document said, so it is kept as `(number "-0")` and written back as `-0`.
- **Duplicate keys.** The `json` reading refuses an object that names a key twice, since a dict holds each key once. The `json-entries` reading reads every object as `(object ["key" value] …)`, a record, so an object stays apart from an array (`{}` is `(object)`, `[]` is `[]`) and member order and repeats are kept. `bl magic` takes a door's readings in order, so a JSON document with a repeated key is read as `json-entries`, and says so; the JSON writer writes `(object …)` back as an object with its repeats.
- **Several texts.** A JSON document may be several JSON texts separated by whitespace (JSON Lines among them), each one value; texts must be separated, so `01` is refused rather than read as `0` and `1`.
- **CSV is strict.** RFC 4180 quoting, refused when a quote is out of place, since Python's lenient mode would silently drop it (`"ab"c` is `abc` there). TSV has no quoting at all, so a quote is part of its cell.
- **XML through expat directly**, with no namespace processing: names keep their prefixes and `xmlns` declarations stay attributes, which is exactly what the document says; ElementTree would resolve prefixes into URIs and drop the declarations. The XML declaration and the BOM belong to the encoding, not the document, and are dropped; CDATA is merged into text, and references to internal entities and characters are expanded. Every element has its attributes dict, `{:}` when empty, so its children always start at the second field, and the dict holds only what the element wrote, not defaults a DTD would add. Expat hands over a long run of text in pieces sized by its buffer; the door joins them, so each run of text is one text and the children don't depend on the parser. An entity reference expat can't expand (declared in an external DTD, like XHTML's `&nbsp;`, or an external entity) is kept where it stands as `(entity nbsp)` rather than dropped, and the internal subset's declarations are kept inside the doctype record in DTD terms (`(ENTITY e "v")`, `(ATTLIST n lang "CDATA" "en")`, `(ELEMENT n "(#PCDATA|b)*")`), which the writer writes back.
- **Dates are records**, every digit kept. `(date 2026 10 2)`, `(time 7 32 0)`, and `(datetime (date …) (time …) (offset -420))` (minutes east of UTC), nesting the same arrangements, with fractional seconds as a `dec` spelled as the document spelled them: `00.500` is `(dec 500 -3)`, never stripped to `(dec 5 -1)`. `tomllib` keeps only microseconds, so the TOML door finds each fraction's digits in the source (outside strings and comments) and matches them to the time `tomllib` read; a document that spells the same time two ways (`.5` and `.50`) is refused, since which is which can't be told. YAML timestamps are read from their spelling by the door itself. Writers that know dates (JSON, CSV, TOML, YAML, XML attributes) write ISO 8601.
- **YAML from PyYAML's node graph**, not its Python objects, so floats keep their spellings, tags become record heads, and the door detects aliases that contain themselves. PyYAML reads YAML 1.1, where `no` is false, `010` is 8, `1:30` is 90 and `2002-12-14` a date; YAML 1.2 reads all of them as text (and `010` as 10). A document rarely says which it means, so a plain scalar the two read differently is kept as the text written, and only what both agree on is typed; a lever can reread the rest. An explicit tag is taken at its word, with the door's own checks, refusing a spelling that doesn't fit it. A tag in YAML's own namespace keeps it in the head (`!!omap` is `'!!omap'`, apart from a local `!omap`). The writer quotes text and tags values that either version would read differently, so its output means the same to a 1.1 reader. Merge keys (`<<`) are kept as the keys they are.
- **Keys spelled alike.** JSON, TOML and YAML keys are strings, XML attribute names and CSV header cells names, so `{1: a "1": b}` or `{a: 1 "a": 2}` would become a document with one key twice, which most readers then quietly collapse. Every writer refuses that, naming both keys.
- **Empty input is silence** for every format: no bytes, no values, nothing written, exit 0, even where a format would read an empty document as something (an empty TOML table).

### Guessing

Each door's `sure(data)` answers 0 to 100; the surest at or above `doors.PLAUSIBLE` (20) wins. The scores encode a few facts: values with frames end in END (0xA0), which UTF-8 text never starts with, so CE that isn't UTF-8 is near certain (95), while CE that is also valid text (`12` is the text `"2"` in CE) loses to JSON. The carrier (92) is a stricter JSON. The textual syntax reads almost anything, so it is only sure (40) when frames appear; a run of loose words is prose (15). One line with commas is as likely prose as CSV (15). On stdin, `bl magic` reads until the start of the stream shows it is CE (a byte UTF-8 couldn't have, before anything breaks CE's rules) and then streams; otherwise it reads the whole input and guesses. A stream of CE atoms that also reads as UTF-8 is therefore only recognised at the end of input, or with `-f ce`.

### Levers reread throughout

The levers apply at every depth, bottom up, keeping marks where they are. `numbers` leaves dict keys alone, since keys are names more often than quantities, and reads only an integer's one spelling (`"007"` and `"02134"` survive as text). `header` leaves out the keys of cells a short row doesn't have (it said nothing there) and keys cells past the header by column number. `typed-records` reads a text head as a symbol, since a record's head names a topic. `drop-keys` and `typed-records` take keys as values: a text or symbol key matches by its spelling, so they work before and after `keys-as-symbols`, and any other key (an integer column number) by equality. `drop-whitespace` drops whitespace-only text only beside records, so `<b> </b>` and an empty comment keep their text.

### Value arguments

`bl search NAME QUERY` and `-l NAME=ARG` read their argument as a value. An argument typed inline is read as the textual syntax first and as CE only if the text refuses, as blcli's `valueArg` does, because a plain spelling often decodes as CE by accident (`10` is the CE of the text `"0"`) while CE rarely survives being a shell argument. A file named by the argument is read as CE first. cli.md's wording ("CE if it decodes, otherwise the textual syntax") reads the other way for inline arguments; this package follows blcli's code, so the same query means the same value to both.

## Compared with blnim and blswift

- **Order from cached bytes.** blswift compares structurally and asserts agreement with the bytes; blnim compares CE order on its `Value`. Here the bytes are cached and compared, so order can't drift from the spec, at the cost of memory. The structural rule is still written out, in the tests, as the reference model the bytes are checked against.
- **No B-tree.** blnim and blswift keep dicts and sets in B-trees. A Python `dict` built in sorted order gives hashed lookups and canonical iteration; updates rebuild, which is fine for values that aren't edited in place (none are, here).
- **Stricter fault positions.** blswift reports a payload fault at the value's header and checks order when a member completes; this decoder judges each rule at the byte that breaks it and compares order as bytes arrive, so it refuses some truncated inputs that blswift would report as truncated, and its offsets point at the offending byte.
- **No limits on encoding.** blswift's encoder refuses what a decoder with the same limits would refuse. Here limits belong to a receiver's boundary, so the encoder encodes any value; only a scalar past the encoding's 4-byte length is refused, when it is built.
- **Empty one-shot input is incomplete**, where blswift reports `truncated` for bytes and refuses `""` for text.
- **Integers** are Python `int`s (blnim: an int64 or the spelling; blswift: `Int64` or the spelling).
- **Value arguments** read inline text first, as blcli's `valueArg` does (blcli's README describes the opposite order; its code reads text first).
- **Search names.** blnim's `Stream[A] = proc(): Option[A]` and `Oracle[Q, A]`; blswift's stream is `Answers` and its search `Search`. Here the stream is Python's iterator protocol and a search any callable, so generator functions, `functools.partial`, methods and classes with `__call__` are all searches without wrapping.
- **The toolkit across implementations.** blcli's `bl` (Nim) dispatches `bl magic` and `bl search NAME` to these Python tools on PATH and lists them in `bl search`; the tools meet only through CE on pipes. One difference from blcli's own tools: malformed input is reported by its corpus reason (`-- malformed input: out-of-order at byte 3`), where blcli reports blnim's prose.
- **Format doors** exist only here. blnim and the JavaScript core have the kind-tagged carrier (`lib/json.nim`, `@bassline/core/json`), which this package has too, as the `carrier` door.
- **Not ported yet**: blnim's `ValueView` (zero-copy views into a buffer), shapes, the store, crypto.

## Testing

```sh
cd blpy
python3 -m unittest discover -s tests
```

`tests/_path.py` puts `src` on the path, so nothing needs installing. 297 tests run in about five seconds; the seven YAML tests are skipped unless PyYAML is installed (they pass with PyYAML 6.0.3).

- **The corpus, three ways** (`test_corpus`). `corpus.bl` through the reader, `corpus.blb` through the decoder and `corpus.json` through the carrier give the same 145 records; the JSON is also read with every dict's entries and set's members shuffled, five times. Re-encoding the records reproduces `corpus.blb` byte for byte, and the carrier and printer write what they read.
  - `ce` cases encode to their bytes and decode back, and fed one byte at a time nothing lands before the last byte; all of them concatenated, in random chunks.
  - `reject` cases are refused with the corpus's exact reason, whole and one byte at a time (refused at exactly the byte that broke the rule), and after a good value in the same input.
  - `starved` cases wait without refusing, whole and byte by byte, and one-shot decoding reports them `Incomplete`.
  - `reads`, `refuses`, `incomplete` and `document` cases, with refused and incomplete told apart; incomplete text fed a character at a time is never refused; `corpus.bl` itself read a character at a time and in UTF-8 byte chunks.
- **Properties on seeded random values** (`test_properties`, generator in `tests/gen.py`): every kind, marks, integers at int64 and uint64 edges and past Python's 4300-digit limit, payloads on the 6/7 and 254/255 length-tier edges, and awkward text (escapes, quotes, delimiters, NFC and NFD, combining marks, controls, CRLF, non-BMP characters, U+2028, a BOM).
  - encoding round-trips; printing and pretty-printing round-trip; the carrier round-trips;
  - concatenations decode one byte at a time and in ragged chunks; text reads a character at a time and in UTF-8 chunks split inside sequences;
  - order agrees with an independent structural model of canonical order (kind, mark, shortlex, members, shorter frame after), and `sorted()` agrees with both the model and the bytes; equality iff equal bytes; equal values hash alike; sets and dicts are canonical whatever order they were built in;
  - `prefixes` and `frame_key` agree exactly with an independent model: the values a value's encoding yields when cut after any whole item and closed;
  - on thousands of corrupted inputs, a decoder's verdict is the same whole, byte by byte and in random chunks, and each refusal's offset is the first breaking byte; sets spelled out of order or with repeats, at depth, are refused at the byte the rules name;
  - under random limits, decoders refuse exactly where the rules, written out separately in the test, say.
- **Search and streams** (`test_search`): `alt` fair beside an endless stream and pulling only what is taken; `alt_from` admitting lazily (the source pulled once for the first answer), a late newcomer joining the rotation, an endless supply of endless streams still answering from the first; `feed` not starving the next value; `first`, `take`, `fan`, `through`; `doors.readings` ranking when asked and reading only when pulled; `Heard` keeping each value once, streams seeing arrivals while pulled, `under`, feeding from a thread.
- **The edge** (`test_edge`): a value read from a pipe before the writer closes, then `Incomplete` at a cut-off; every kind of source, and a buffered file that has read ahead losing nothing; a write to a non-blocking pipe waited on, not dropped; a writer answering `False` once the reader has gone; values out and back through a running `bl-search-numbers` (the answer back before the pipe is closed); a command that has exited; a command whose output is cut off; what `into` raises coming back at `close()`. Through the shims as subprocesses: an answer before stdin closes, exit 0 and silence when downstream goes away mid-stream, exit 1 and one line for input ending partway through a value, the corpus reason for malformed input, empty input as silence, `-n` and the long-option spellings.
- **Doors** (`test_doors`): each first pass's shape; a 30-digit integer and `1.50` exact both ways; negative zeros; every refusal in formats.md; duplicate keys refused by one reading and kept, in order, by the other and written back; JSON round trips on random values; CSV quoting, strictness, dict rows under one header; TSV's literal quotes; TOML's dates, times and float spellings, fractions of a second with every digit (past `tomllib`'s microseconds, and not fooled by strings or comments), a round trip that `tomllib` reads, and the writer's refusals; XML's prefixes, namespaces, comments, PIs, doctype and a round trip, a 20,000-character run of text as one text, entity references kept, the internal subset's declarations kept and written back, and no attributes a DTD would default; every writer refusing keys it would spell alike; CE, text and the carrier on random values, and `corpus.json` through the carrier door equal to `corpus.blb`; YAML's tags, floats, anchors, sets and cycles, the scalars YAML 1.1 and 1.2 read differently kept as text, explicit tags checked, and output a 1.1 reader reads the same way; the number and `dec` spellings; guessing each format, the corpus files, text that happens to be CE, prose, extensions.
- **Levers** (`test_levers`): each lever at depth, with marks, and its refusals; keys and heads as values (`"a,b"`, the integer key 1, a text head); levers in order; a lever answering two readings; writing stopping on `False` and not on silence; every lever having a shim and a console script; value arguments read inline as text first and from a file as CE first; the tools' `--help` first line, queries by recognition, misuse and refusals.
- **bl magic** (`test_magic`, through the shims): JSON to CE to text; CSV with `-l header -l numbers` to a JSON file; `--readings`; `--formats` and `--levers`; a lever as a CE filter; empty input; `-f`/`-t` over extensions and what is said on stderr; guessing every format from stdin and files with no known extension; output formats by extension; misuse (exit 2), unreadable input and unwritable output (exit 1, one line), a writer refusal naming the output; falling back to the `json-entries` reading; XML with `drop-whitespace`, TOML to JSON Lines; `--readings -f` taken at its word; a `bl-search-NAME` from PATH used as a lever, with its argument, between two of magic's own; running the shims straight from PATH.
- **Edge cases** (`test_values`, `test_codec`, `test_text`, `test_ops`, `test_carrier`): `bool` and `float` refused before `int`; lone surrogates; cycles; values never equal to Python objects; NFC versus NFD; integer boundaries; tier edges and their non-minimal forms; depth and size limits, including a declared length refused before its payload; a failed decoder or reader staying failed; offsets across compaction; the reader's timing (frames at the bracket, atoms at the next delimiter); marks in every position; escapes; `go!!(a)`; pattern matching; readings in and out; carrier refusals; a 20,000-deep value through every operation.

The tests were checked for teeth by breaking the code on purpose, running the suite, and restoring it. Each of these made it fail:

| broken on purpose | failing tests |
| --- | --- |
| renamed the `out-of-order` reason | 13 |
| flipped the shorter-frame rule when sorting set and dict members | 10 |
| flipped the shorter-frame rule in the decoder's order check | 10 |
| moved the medium/large length edge in the encoder (254 encoded long) | 13 |
| moved the small/medium edge in the decoder (a length byte of 6 accepted) | 1 |
| dropped the duplicate check | 8 |
| let `Integer()` accept `bool` | 1 |
| let `bool` through both the default reading and `Integer()` | 2 |
| stopped escaping the closing quote when printing text | 7 |
| took `!` out of the delimiters (so `go!!(a)` fails) | 10 |
| cut a number at its first non-digit (so `42px` reads as `42 px`) | 40 |
| dropped the check that a trailing mark ends at a delimiter (so `a!b` reads as `a! b`) | 6 |
| judged escapes only once the closing quote arrives | 3 |
| reported incomplete text as refused | 37 |
| stopped checking UTF-8 in symbols | 6 |
| judged a bad integer at its header instead of its first bad byte | 9 |
| let a refused decoder resume | 7 |
| let `plain` merge a symbol key with a text key | 1 |
| normalised text to NFC | 1 |

For pillar 3 and the doors, each of these made the suite fail (run with PyYAML present):

| broken on purpose | failing tests |
| --- | --- |
| `alt` draining each stream before the next | 5 |
| `alt_from` admitting a newcomer only once the others are done | 5 |
| `chunks` reading to the end before handing anything over | 4 |
| a text writer raising on a closed pipe instead of answering `False` | 1 |
| input ending partway through a value exiting 0 | 2 |
| malformed input reported without its corpus reason | 1 |
| JSON floats read through `float` | 5 |
| the last of two duplicate JSON keys winning | 4 |
| a negative zero read as 0 | 4 |
| `NaN` let through as text | 4 |
| CSV read leniently | 2 |
| TSV reading quotes as quoting | 1 |
| XML leaving out an empty attributes dict | 4 |
| TOML keeping a float's leading `+` | 1 |
| the TOML writer letting a 30-digit integer through | 2 |
| the text door as sure of prose as of values | 3 |
| CE guessed even when it reads as UTF-8 text | 1 |
| `-f` ignored when the file has an extension | 1 |
| nothing said on stderr about a guess | 9 |
| `numbers` reading `007` as 7 | 3 |
| `header` filling short rows with nil | 1 |
| `typed-records` keeping a text head as text | 1 |
| a send answering nothing taken as "gone" | 1 |
| `keys-as-symbols` dropping marks on keys | 1 |
| `doors.readings` not asking the doors how sure they are | 2 |
| inline value arguments read as CE first | 2 |
| a lever's argument flattened to a symbol of its spelling | 2 |
| YAML 1.1's reading of plain scalars let through | 2 |
| YAML timestamps read through PyYAML's constructor | 2 |
| TOML fractions taken as `tomllib`'s microseconds | 3 |
| XML text handed over in expat's pieces | 4 |
| XML attributes a DTD would default added | 1 |
| XML entities expat can't expand dropped | 1 |
| writers letting keys spelled alike through | 3 |
| `drop-whitespace` dropping a record's only text | 1 |
| a buffered file read through its descriptor | 1 |
| a non-blocking channel's unwritten bytes taken as written | 1 |
| no levers from PATH | 1 |
| `--readings -f` held to the plausibility bar | 1 |

"CE guessed even when it reads as UTF-8 text" first passed every test; the guessing test for text that happens to be CE (`12`, `0`) was added for it. Treating a send that answers nothing as "gone" was a real bug, caught by the test that a lever may answer several readings. The last fourteen rows are the fixes from a review by the bassline-reviewer agent, each with the test that now pins it.

Removing only the default reading's `bool` rule changes nothing: `Integer()` refuses `bool` on its own, and the rule is there for its clearer message. An outside review found that the number-cutting and mark breakages first passed every test, because refusals were asserted only through `read`, which refuses any text holding two values; refusals are now asserted on whole documents too.

## Not built yet

- **Shapes** (values with holes, matching and filling), and with them `bl search match`.
- **Sockets.** The edge reads and writes file descriptors, files and commands' pipes; a listener or a place (`tcp://`) is blcli's `bl serve`, `bl send` and `bl reach`, which these tools pipe with.
- **More doors**: Markdown, SQLite, CBOR and MessagePack, S-expressions and EDN (formats.md has their readings), and levers such as dates and UUIDs recognised in text, or empty cells as silence.
- **An entries reading for YAML**, as JSON has, for mappings that repeat a key.
- **Digests** (BLAKE2b-256 and SHA-256 over CE bytes) reproduce natively with `hashlib` but aren't wrapped yet; signatures are monocypher's EdDSA over BLAKE2b and would go through blnim.
- **Zero-copy views** into a buffer, as blnim's `ValueView`.
