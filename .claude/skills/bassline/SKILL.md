---
name: bassline
description: The bassline model as it stands now, ahead of the code. Use whenever you design, build, review, explain or discuss anything in bassline — values and the canonical encoding, dialects, searches and streams, sends, scouts, format conversion, the edge — or touch code in packages/blnim, packages/blswift or packages/core (@bassline/core), even for a small change. Also use when anything in this repo mentions oracles, Msg, reply, gas, the router or PubSub (old names this skill corrects), and when a conversation turns to programming without shared semantics, partial information, or local-first and P2P design here.
---

# Bassline

Bassline is a way of programming with no root semantics. There is no fact of the matter about what a value means. A program finds out what a value means to it, and what it can do with it, by asking locally. There are many answers, and none is final. What a value means can differ each time you ask; most of the time it will be stable, but never rely on that.

Everything is local. There is no whole system: nobody controls it, nobody knows it, and there is no central server, because a server is not a concept here. There is only a local thing that knows how to talk to one. Bassline is peer to peer in the strongest sense.

Two motives drive it. The first is growth. A system whose parts share one worldview pays for that agreement up front, everywhere, and can only change as fast as everyone agrees; bassline makes agreement optional and local. The second is getting away from registers: no single value assignment, no "the value of X", no finality.

The problem splits in two. Speaking outward is settled: sends go one way, carry self-contained values, and don't care how anything responds. The hard half is building understanding incrementally, working out what follows from what you know, some of it fixed in code and some discovered late. Search is the central construct for that half.

## The model is ahead of the code

The repository lags the model, and stale code is being deleted as it settles. Read code for how things are built, not for what they mean. Don't learn the model from the deleted message model that older code and notes still mention (`Msg`, `reply`, `gas`, the pool, the router), or from the store, an exploration that will change. `Oracle` is the old name for a search.

`data-model.org` is the authority on values. Prefer it over any summary, including this one.

## Three pillars

Every implementation stands on three pillars, and a minimal one has all three, small: values and their encoding; working with values in programs; and search and communication, meaning finding out locally what things entail plus the local capability to send, tied to no networking protocol. The programming model and the dialects programs speak are built on top.

### 1. Values

A value is an atom or a frame, and any value may carry a mark.

- Atoms: nil, integer (any size), text (UTF-8, never normalised), symbol, bytes.
- Frames: list (by position), record (a head value, then fields), dict (keys to values), set (unique members).
- The mark is one header bit: "something to do" instead of "something". It is the sender's declaration and does not flow into children. What it asks for is up to whatever evaluates it locally, outside the value space.
- Identity is the CE bytes. Two values are equal exactly when their CE bytes are equal. Dict keys and set members are ordered by their CE bytes.
- There are no booleans and no non-integer numbers. Those are vocabulary: symbols, presence in a set, `(dec 15 -1)`.
- Nil is a stated absence. Silence, a value not being there at all, is different.

Text syntax at a glance:

```
nil  42  -7  1_000  "text"  sym  'quoted sym'  0xdead_beef
[a list]  (head field field)  {a set}  {key: value}  {}  {:}
go!  "hi"!  !(do this)  !{k: v}        ; mark: atoms suffix, frames prefix
```

Values don't have to be universally understood, so they can be tiny and let entailment carry the exchange: `10 PRINT "HELLO" 20 GOTO 10` is a few bytes that entail an endless run. And because sends go one way, a value carries what it needs instead of leaning on a channel, a session or shared state. Values are self-contained, but not self-describing.

Details, including the encoding: [references/values.md](references/values.md).

### 2. Working with values

What any program can do with values, with no shared vocabulary at all:

- compare and sort them (CE order), test equality, hash, sign and deduplicate them (CE bytes);
- write them one after another as a bare concatenation of CE (a `.blb`), which a resumable decoder reads as bytes arrive;
- scan by prefix: CE spells a record's head first, so a prefix is a query for every value under that head;
- match shapes with holes and fill them;
- walk, map and fold them; print and read them as text.

A value is not changed after it is built; operations build new values. A reading that cannot hold a value refuses it. Never coerce, truncate or normalise, and handle marked values everywhere you handle values.

A value is never a reference. A digest record such as `(digest sha256 …)` (bytes elided) is a value with a reading that may yield its preimage, if you have it. Graphs live in readings over trees.

### 3. Search and communication

**Search.** Two things, kept apart:

- A **search** is what you ask. Hand it a value, or anything else, and it starts finding out what that entails.
- A **stream** is what it hands back. You pull it, one answer per pull.

What a search does once asked is its own business: it may work ahead, in the background, across machines, or only when pulled. Pulls decide how much you take, not how much it does.

- Late binding is the everyday name, but it is really late discovery: what is reachable from this value given what is known by then. There is no single target being looked up.
- Answers only accumulate; there is nothing to retract, because there is no truth to check them against. Keep pulling to see what has become known; once a stream has nothing more, asking again starts a new one.
- Either side may stop: the stream may have nothing more to give, or the consumer may take no more. Neither is finality. "The result" is just the answer somebody took.
- Evaluation is a search, and evaluators are à la carte: there is no central evaluator and no blessed interpretation. A lambda-calculus search can yield every reduction step, or only the normal form, or one step and stop.
- Answers can be values, objects, closures, sends, other searches, or which searches exist.
- A search is always local, part of your own running programs, even when what feeds it came from elsewhere or its work is split across machines. It is a program talking to you. It is not receiving: not a socket, buffer, channel or asynchronous receive. Receiving matters only at the edge.
- What a search can reach grows locally: values handed in at the edge, values sent to local programs, what scouts gather. Sending is how things get somewhere; searching is how you find out what they entail.
- Streams combine with `alt` (take turns), `cat` (one after another), `map`, `filter` and `take`. Searches combine into new searches: one that asks several searches and alternates their streams, or one that taps another with an objective, is itself a search.
- Interface views, actions and search, and batch aggregation generally, are all searches. A new view is one more answer, not a new mechanism.

This is what replaces registers. Nothing holds "the" value of anything: you ask, and treat the answer as a conversation, not a variable. Knowledge is kept however suits (sets, or any local construct), and a search's internals or a program's working state hold whatever they like; what the model rejects is a single slot standing for what something is. Dropping what you hold is a local decision, and nothing relies on it.

**Sending.** A send is local. It takes a value and may answer, as a plain host yes or no, whether it was understood enough to act on. For a send that only carries bytes somewhere, that can only mean it was accepted for carriage. It never answers what happened, and there is no reply path, not even locally. Whoever needs to talk to someone finds out whom by searching. A tool that talks over a wire is still a local tool.

**Negotiation.** A search can answer with other searches and sends; those searches answer with more, so programs discover what they can do with one another as they go, with no protocol agreed in advance. Nobody invokes someone else's search: the most you can do is send a value that leads someone to begin a search of their own and send what they find somewhere you can search over or hear about.

**Scouts** (a loose idea, not built yet). A scout is autonomous: something you spawn that runs on its own for a long time, collects information, and sends it on to something else, such as whatever feeds your searches. It can also be thought of as a value: a self-contained, long-running search that responds to nothing, which you or another machine may run on your behalf if it can interpret it, because a value is speakable. A search may start one in response to something you asked. How it runs inside doesn't matter; an LLM agent is one possible way. Sending a value that leads someone to begin a search of their own is similar.

Worked examples: [references/search.md](references/search.md).

## Dialects and readings

A dialect is an arrangement of values that some programs recognise. A record's head names a topic with no vocabulary needed. A dialect is not a schema: it constrains nothing and requires no one else to hold it. What a value means to you is whatever your searches find it entails, and the same value can have many readings at once, none of them blessed.

## Format conversion

Converting formats is a little compiler, like Pandoc but richer. A trivial pass reads a foreign format into values; the options and customizations are searches and sends that refine them; a writer emits another format. Bassline is the richer side, never a foreign format. Going out is lossy, and rendering is just another reading. The bar is empirical: conversion through bassline has to be measurably better than the alternatives. Building doors: the `bassline-zoo` skill.

## The edge

The edge is where bytes from elsewhere become values and values leave: listeners, transports, pipes, a small program that lets one implementation speak to another. It hands values in and offers sends out. Nothing about connections, addresses, sessions or peers passes it.

How an edge tool decides where values go is its own business. A connection can be offered inside as a send, found by search like any other; nothing ties it to the value that arrived on it. Where something came from shows up as which local send the edge fed it to, or as what the value itself carries (a signature), never as the channel.

## Instincts to stop on

Almost every familiar tool quietly assumes a single referent or a ground truth: binding, resolution, completeness, a reply path, "the result". Each one, reached for by habit, fills the absence back in. When one shows up in a design, find the bassline shape instead.

| Reach | Why it leaks | Instead |
| --- | --- | --- |
| A reply path, a message carrying where to answer, request/response pairing | Assumes a definite counterpart | A value and a send; whoever must speak finds whom by searching |
| One answer or none where there could be several: first-match routing, `resolve()` | Decides finality for the consumer | A search; the consumer stops when it has enough |
| Modelling what something is as one held value: a field, cell or register that _is_ the X | Single assignment | Ask a search |
| One lookup table you look everything up in | A single place that says what things are | Searches, over knowledge kept however suits |
| A schema, type field, version field, or validator as a contract | A shared worldview | A local reading |
| A registry, directory or server | A non-local fiction | A local thing that knows how to reach one; a search that answers whom |
| A reference or pointer as a kind of value | Puts a reading's behaviour into the value | A value with a reading |
| Retraction, revision, truth maintenance, consistency | Assumes a truth | Answers accumulate; keep pulling, or ask again |
| Coercion or normalisation: floats, booleans, rounding, Unicode normalisation | Loses what was said | Refuse |
| Close messages, cancellation travelling upstream | Lifecycle propagation | A local decision |
| Logic programming, propagators and cells | One evaluation model, or write-heavy cells rooted in one correct value | Evaluators à la carte, each a search over a space of entailments |
| Actors, RPC, pub/sub topics, CRDTs | A named counterpart, a channel, or an agreed merge | Sends, and searches over local knowledge |
| Values with object identity | Identity other than the CE bytes | Say in the value what tells them apart |
| "The system", "the network", "the protocol" | There is no whole | Name the local participant |

## Designing in bassline

Before writing code, answer these. If an answer is fuzzy, the design is not ready.

1. What value am I handing over, and is everything it needs inside it, with nothing depending on a channel, a session or shared state?
2. What searches would make sense of it locally, and could someone add another later without touching mine?
3. Where am I choosing one answer, and is that my choice or the consumer's?
4. Does anything remote cross the edge?
5. What can a program with no shared vocabulary still do with this?

## Speak in values

When you produce something another program or agent will consume, or that gets saved (findings, inventories, test results, handoffs between agents, `.bl` files), write it as bassline values in the textual syntax rather than Markdown. Values can be read, matched, filtered, hashed and fed to searches; Markdown can only be read. Prose belongs inside text atoms, where it stays readable. In replies to a person, prose is fine, but findings, lists and records someone may reuse still go in a values block.

```
(finding {
  file: "packages/blnim/src/bl/lib/server.nim"  line: 132
  kind: local-remote
  leak: "the listener hands program logic a reply path back over the socket"
  instead: "hand the landed value to a send; whoever must answer finds whom by search"
})
```

No booleans or decimals: use symbols, sets and records, and mark only what is meant to be acted on.

## Working in this repository

`CLAUDE.md` has the layout, build commands and house rules. It doesn't cover blswift, which has the first pillar, shapes and searches. The JavaScript `packages/core` has values, CE, the text syntax and the JSON dialect, and no search or crypto. All of them run `corpus/corpus.bl`.

- Hard-but-useful work: [references/frontiers.md](references/frontiers.md).
- Other languages, interop and format doors: the `bassline-zoo` skill. Reviewing a change for leaks: the `bassline-reviewer` agent.
