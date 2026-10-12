# Search: worked examples

Worked examples of the model in SKILL.md.

## Contents

- Python conventions
- A search that works when asked
- Shapes: matching as a search
- Evaluation: several searches over one term
- Whom to talk to
- A shared list
- Discovery and negotiation
- Interfaces: views, actions, search
- Grading
- Format conversion
- Composing
- In the code today

## Python conventions

The examples are Python. The simplest search is a function containing `yield`: calling it runs none of its body and returns a stream (a generator), and each `next(stream)` runs it to the next `yield` and hands back that answer. That is a fully lazy search. A search can as easily do work the moment it is asked and hand back a stream over what it found; the first example is one.

```python
def steps(term):              # a search
    while (term := reduce_once(term)) is not None:
        yield term            # one answer per pull

stream = steps(t)             # asking
answer = next(stream)         # pulling one answer
```

Helpers stand for whatever an implementation provides: `first(s)` and `take(s, n)` pull from stream `s`; the combinators are under Composing; `rec(head, …)` and `sym(name)` build values; `prefixes` and `under` are value operations, and filling a shape is a search.

## A search that works when asked

```python
class Planner:
    """Plans when asked; the stream hands the plans over cheapest first."""
    def __call__(self, goal):
        plans = make_plans(goal)                  # the work starts on asking
        return iter(sorted(plans, key=cost))      # the stream

stream = Planner()(goal)
first(stream)                                     # take one, or more
```

A search could equally start workers, consult whatever it keeps, or split the job across machines. The asker only ever sees the stream.

## Shapes: matching as a search

A shape is a value with a logical template in it: some parts stand for whatever fills them. Matching is a search for fillings. Today's form is a record, `(shape example holes)`, naming which symbols in the example are holes.

```python
def matches(shape, known):
    """Every way `shape` fits anything known, as bindings."""
    for value in known:              # known: a list or stream of what is known
        yield from fillings(shape, value)

# matches((shape (tag x) {x}), [(tag red) (tag blue) other])
#   answers {x: red}, then {x: blue}
```

This search is how unification works: holes filled however the shape allows. A matcher that returns one binding or nothing cannot say "red, and also blue".

## Evaluation: several searches over one term

An evaluator is a search, and different evaluators are different searches over the same value.

```python
def normal_form(term):
    """Only the end of the road, if the road ends."""
    for term in steps(term):
        pass
    yield term

first(steps(t))           # one step, then stop
take(steps(t), 1000)      # as far as I care to go
first(normal_form(t))     # the end; this pull never returns if there is none
```

Neither is the meaning of `t`. Another could reduce in a different order or plan the work; the consumer sees only answers, and chooses which search to ask and how much to take.

## Whom to talk to

There are no reply paths. Whoever wants to say something finds out whom to say it to by asking.

```python
def whom(value, interests):
    """Sends that local knowledge says care about values like this one."""
    for prefix, send in interests:       # kept however suits
        if prefixes(prefix, value):
            yield send

for send in whom(v, interests):
    send(v)
```

`whom` is one search among many, and others may answer differently: by signer, by history, by evaluating something. An interest in a prefix is not a pub/sub topic. A topic only exists inside a pub/sub system that everyone has agreed to; an interest is a purely local thing, and nobody else needs to know it exists.

## A shared list

Two devices share a grocery list. Neither holds "the list". Each keeps what it has heard, however suits it, and every change is one more statement:

```
(want "oat milk" (week 2026 40))
(want "eggs" 12 (week 2026 40))
(got (want "oat milk" (week 2026 40)))
```

```python
def to_buy(known):
    """Each want with no got known for it, as of the pull."""
    for want in under(known, rec(sym("want"))):
        if rec(sym("got"), want) not in known:
            yield want
```

Removing, changing a quantity and undoing are all further statements, and a search decides what it makes of them. Within one stream, answers only accumulate; a new ask can answer differently, so after a `got` lands, `to_buy` stops yielding milk. Statements that must stay distinct say something different, such as an occasion or a signer, rather than carrying IDs. Values cross between the devices at the edge, by whatever tool is at hand.

## Discovery and negotiation

A search can answer with other searches, and with sends.

```python
def experts(value):
    """Searches that may have something to say about `value`."""
    ...

answers = alt_from(search(value) for search in experts(value))
```

`alt_from` pulls the next search from `experts(value)` on its turn, so a search learned a moment ago can join, and an endless supply of experts doesn't hold up the first answers. Across programs, see Negotiation in SKILL.md.

## Interfaces: views, actions, search

An interface is a set of searches over the values on screen.

```python
def palette(selection, typed):
    found = alt(alt_from(actions(v) for v in selection),
                over_selection(selection))     # actions on the whole selection
    return (a for a in found if any(typed in label for label in labels(a)))
```

- An action can be a closure, or a marked value handed to a send that does it. Marked actions deduplicate by CE.
- A label is a reading, so one action can have several.
- The selection and the typed text are local input to the ask. Every keystroke asks again, and the old stream is simply dropped.
- A new view or action is one more answer somewhere, not a registry entry. Asked about a value it hasn't seen, a view search may evaluate its way to a view.

## Grading

Tapping a search with an objective gives a new search. One choice is to answer only improvements, so the consumer always holds the best so far and is never told it is final.

```python
def improving(answers, score):
    best = None
    for a in answers:
        if best is None or score(a) > score(best):
            best = a
            yield a
```

Online algorithms fit the same way: running estimates, top-k, bandits choosing which search to pull next. Each is a search over streams.

## Format conversion

The levers are the searches in the middle:

```python
docs = read_json(text)                                # trivial pass
docs = (d2 for d in docs for d2 in dates_as_records(d))
docs = (d2 for d in docs for d2 in drop_keys(d, {"internal"}))
for d in docs:
    write_toml(d)                                     # out: lossy, and fine
```

## Composing

Streams combine:

| Combinator | What it does |
| --- | --- |
| `alt` | Takes turns between streams, so an endless one cannot starve the others |
| `alt_from` | The same, admitting streams lazily from a stream of streams |
| `cat` | One stream after another; only when every earlier one ends |
| `map` | Each answer transformed |
| `filter` | The answers a predicate accepts; the rest are pulled past |
| `take` | Up to `n` answers, pulling no more than that |
| feeding | Each answer handed to a search, whose streams come out |

## In the code today

- Nim: `packages/blnim/src/bl/queries/search.nim` has `Search[Q, A]`, a ref object closing over its context, and denoted spaces (below); `stream.nim` has `Stream[A] = proc(): Option[A]` and the combinators; `rewrite.nim` fills shapes as a search for compatible bindings.
- Swift: `packages/blswift/Sources/Bassline/Search.swift` has the `Search` protocol and `Answers` for the stream; `ShapeSearch.swift` does shape matching as a search.
- `Oracle` is the old name. Say search for what you ask and stream for what it hands back.

## Denoted search spaces

A search closes over whatever it answers from; how is its own construction. Some searches can also be written down: their space denoted as a value, which interpreting turns back into a search whose answers are rebuilt from their values by the answer type's reading. So richer things than values (a peer and its connection, a closure) can be spoken about through their denotations: a peer table written down when disconnecting is read back into peers that connect again.

```
!{!(kind search-space) (identity ID) (holds {(Q A) …})}   ; holds a set of records
!{!(kind search-space) (identity ID) (holds {Q: A …})}    ; or a dict: one answer a query
!{!(kind search-space) !(kind ranked) (identity ID) (holds {(Q R A) …})}
!{!(kind search-space) !(kind cat) (identity ID) (parts [PART …])}  ; alt, feed, merge likewise
```

- These are objects: a marked set of records shaped as answers. An unmarked `(Q A)` is something the object answers; a marked `!(Q A)` is an order, such as its kinds, `!(kind K)`, which together say how to bring the thing about (a search space that is a cat is both). Every kind of every object is found like any answer, by its head. An object with no kinds is a description to find a thing by, and what a thing is called is its answers to `identity`, one record per name.

- Names let other values speak of a space without copying it (closures as values form a spaghetti stack of spaces). Two things are the same for a reader when their `identity` answers meet, and learning another name is a union: identity accumulates like answers.
- Not every set is a search space, and most searches are never written down: most spaces aren't worth the bytes. Those that are can be memoised and talked about like any value, which is how an evaluator's findings become test cases and material for generative programs.
- Ranked and unranked are different searches; nothing defaults a rank.
- Asking and answering are both writes, told apart by arity: `(q)` asks q, `(q a)` says a answers q, `(q nil)` says the answer is nothing (unlike silence, no record at all). Nil is a valid query and a valid answer, so it can't mark either. In a set, `(q)` sorts after q's answers, so one run holds a query's question and its answers. An answer is matched to its question by what it carries, never an ID.
- A space keeps an answer as its type's `toValue` and rebuilds it with `fromValue`. A send is read back by a search from identities to sends, since what an identity reaches depends on where it is read.
- A bvar is a program-level construct: a send and a search over one place. Like a search it can be written down when its halves can, `!{!(kind bvar) (identity ID) (send …) (search …)}`. A send is an object like a search; written down it is opaque, `!{!(kind send) !(to ID) …}`, saying only what it sends to (the marked `to` is an order, not data), and what those are is found by asking about their identities. Reading one back is a search from identities to sends.
- A bvar is a place to put values and search what has been put: the write half is a send, the read half a search, so it is not a register (answers accumulate, and in a single-valued one the first answer stands). A memo keeps a search's answers in one and answers from them first; kept in a file, the memo persists and comes back.
- Fan-out is part of a search: any number of answers a query (set semantics) or at most one (dict semantics), two parallel meanings. A dict space reads back as a single search, and memoising one keeps a dict.
- Searches compose into searches, and so do their denotations: a search space whose kinds include `cat` (a scope, then the scope around it), `alt`, `feed` (each answer asked of the next search) or `merge` (ranked searches by rank), with its parts in order under `parts`. A part is written whole or named by identity; a name is resolved when the search is asked, through a search of known spaces, so it sees what is known by then. Every answer a denotation gives is read: several `holds`, `parts`, sends or searches all count, since learning more about a thing is a union.
- A record the reading refuses raises, unless the interpreter is told to skip refusals.
