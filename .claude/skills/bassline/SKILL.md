---
name: bassline
description: Use when designing, building, or reviewing Bassline programs, or touching code in core/, dialects/ or legacy/, even for a small change. Covers values and canonical encoding, tracks as local working memory, monitors, dialect readings, and what crosses the edge. Also use when code or notes speak of searches, sends, bvars, spaces, oracles or Msg, older constructs this skill places in the track model.
---

# Programming with Bassline

Bassline programs work from partial information. A producer can contribute a value before anyone knows how to use it. A reader can come along later, recognise a dialect, and make something of what the program already holds.

## Values travel

Programs share a grammar. A value is an atom (nil, integer, text, symbol, bytes) or a frame (list, record, dict, set). Any value may carry a mark indicating something to do. Its canonical encoding (CE) is its identity. Two occurrences of the same value can still matter separately. A dialect gives an arrangement of values meaning to the programs that recognise it.

Preserve marks and exact values. A reading that cannot hold a value refuses it, and never coerces, truncates or normalises it. Transport carries self-contained values. Sockets, callbacks, and live host objects belong to the process that holds them. A value is never a reference. A digest record such as `(digest sha256 …)` is a value with a reading that may yield its preimage, if you have it. Graphs live in readings over trees. [Value specification](../../../data-model.org) · [Encoding and syntax guide](references/values.md)

## Tracks remember

A **track** is the interface for contributing and reading local information. Offer a node with `add`. If `keeps` admits it, the track retains that occurrence in local order, even when no monitor is attached. A reader can inspect it for as long as the track holds it. Equal values can occupy separate slots. Slots are never renumbered and a track only grows. Whoever holds the track can revise it as a step of its own, replacing what a slot holds or leaving the slot vacant. Nothing is moved or appended by a revision, and a revision is not asked of `keeps`, so a track that keeps an index updates it in its own `revised` hook. Since a revision can put any node in a slot, a reader that caches by position, or relies on what `keeps` admitted, reads again on `revised`. Carry an originating jam or its rank when a later reader needs it.

By default a relay adds another occurrence each time it hears a value. A route that can circle back needs a way to recognise redelivery. Choose its key from what identifies the occurrence at its source. For a track that also materializes entries, a keyed insertion proc can recognise retransmissions before calling `add`.

A position is this track's own order. It stays put, but it means nothing to another reader. When another reader needs the order, put it in the entry, as a jam puts its rank in what it tells.

To answer a question, read the present entries directly. Give a specialised track an ordinary proc or iterator for a recurring question, such as which builds concern a task. A specialised track hears its own writes before any monitor does, so it can keep the index that its `keeps` and its queries read. A reading can draw on several tracks. When people need to author, share, or teach a question, express it as a value that a local reader can interpret over its tracks.

## Monitors read and react

Attach a **monitor** when a reader needs to follow changes. On joining it can scan the entries already held. It can maintain an index, materialize a dialect reading in a node, or offer selected occurrences to another track. A collector can remember a teaching after the source forgets it. A view that follows the source can instead rebuild when a slot is revised. Vacating a slot changes what one track holds. It does not withdraw what was said, and a track that kept the value still holds it.

Let the component that needs the observation own its lifetime. A panel can detach when it closes. A collector that must keep hearing teachings stays attached while the panel is closed. A monitor attached inside the track's own `added` hook can see the current occurrence twice, first in its joining scan and then in its `added` callback. An effect that should happen once needs a way to recognise that occurrence.

For example, a room can keep `(build 433 failed)` before a task board understands it. Later the board encounters a convention for reading builds and learns the task name `fix-433`. It can revisit the old occurrence. A builder that adopts the convention can use that name in its next build report. Another reader can continue using the number. Refreshing the board can use the old occurrence. Announcing a new failure requires evidence that this is a fresh report.

In the Nim implementation, a node can hold a plain value or a live host object. Materializing part of a held node is a revision of its slot, and a revision is the holder's own step. A monitor hears changes during a write, when a revision would raise, so the reading it makes lives in a node of its own or in a value it offers to a track the holder reads, and the holder revises from that once its write returns. A monitor attached outside a write can revise in `joined`. Within a revision the draft sees what earlier edits in it left. A live reading can implement `reified` to recover the original value for another reader or for transport. [Nim guide](../../../core/nim/README.md)

A live object equals only itself. Once a reading has made part of a node live, the node no longer equals the plain value it came from. A `keeps` gate or an index that compares by value compares what `reified` gives, or keeps its own key from the plain entry.

An iterator can derive answers as they are pulled. If it pauses at a slot, a revision can replace or vacate what the slot holds, though the slot itself stays put. A reader can take a snapshot to finish a question against the earlier entries, or follow revisions with a monitor to answer against the current ones.

## Writes take turns

A track applies one write at a time. It tells its own hooks first, then attached monitors in attachment order. An `add` made while a write is under way waits its turn and answers that it was staged. The track asks `keeps` about it when its turn comes, after the current change has reached every monitor. A revision doesn't wait: one begun during another write raises. A draft that raises discards its edits and the additions staged during it. A hook that raises after commit leaves the change in place, and doesn't stop the turn. Every monitor and every staged addition still has its turn, and the writer then receives the first error.

Within a revision each edit sees what earlier ones left, and an edit that leaves a slot as it was tells no one. Monitors hear the revision once, with each changed slot and what it held before.

## Reading earlier code

Older `spaceVar`s already retained answers under a question. A default track retains occurrences before a question is chosen. When adapting existing code, preserve the meaning the caller relies on. For example, a dict space accepts an identical answer again and refuses a conflicting one. A jam ranks retained puts and can also tell a value it doesn't keep to the lines asking for it then.

Older code also speaks of messages, oracles and sends. `Msg` and reply paths are gone. An oracle was the old name for a search. What a send did is now an `add` to a local track, and a monitor that writes what a track admits to an output is how values leave.

A reader can ask an ordinary proc or iterator about one or several tracks. For a derived sequence that readers want to share, a producer can keep the computed prefix on a track. Its procedure decides when to do another step, where to resume, and which changes to its inputs require starting over. One-off reads can compute just the answers their caller takes.

A monitor attached to the track sees changes through any writer and can copy them to another memory or to a file. When a caller needs confirmation of a durable write or an external action, that confirmation belongs to the component doing the work.

## What stays out

Each of these assumes a single referent or a whole system. When one shows up in a design, find the local shape.

- A reply path or request and response pairing. Offer the value to a local track. Whoever must speak decides whom from what they hold.
- A slot treated as what something is. A slot holds one occurrence in this program's memory. What it means is a reading.
- A registry, directory or server that says what things are. There are local tracks and the readings over them.
- A schema, type field or validator as a contract. A dialect constrains nothing, and a track can keep a value no reader recognises yet.
- Removal as retraction. Forgetting is local.
- Close or cancellation sent to others. Closing is a local decision.
- "The system", "the network" or "the protocol". Name the local participant.

## Before building

- What value does the producer contribute, and does it carry what a later reader needs?
- Which track admits it, and what does its `keeps` refuse?
- Which readers query the entries, and which follow changes? What does each do when a slot is revised?
- Where does a reading choose one answer, and is that its own choice?
- Does anything about a connection reach past the edge?

## Working here

Use Bassline text for findings, inventories, and handoffs intended for programs or agents. `core/` holds only what every program needs to take part. A new kind of track, a monitor, a kind of live object or a reading belongs to the dialect it serves, in `dialects/NAME`, beside whatever else speaks that dialect in any language. The repository guide covers layout and builds. The zoo skill covers ports and format doors. [Repository guide](../../../AGENTS.md) · [Porting guide](../bassline-zoo/SKILL.md) · [Research notes](references/frontiers.md)
