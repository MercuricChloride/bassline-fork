# Bassline

A system for partial information programming.

Bassline programs work from incomplete messages. They build local understanding from what they have, act on new information, and continue.

Anything outside a local perspective is encountered through communication. When that communication yields information that matters, we observe it as a resource. We do not need a complete account of what it is, where it is, or how it produces what we receive.

## Core Idea

Bassline is word/message-first.

A word is a two-lens binding: an early-bound noun and a late-bound verb. A message is a fragment of partial information that names words with string keys. It is anonymous, sovereign data with no privileged interpretation. A word's verb is an opaque, message-relative way to speak.

Think of verbs as captured communication context. Like a closure hides its captured lexical environment, a word hides the local machinery its verb closes over. From the outside, you only see the word and the affordance it exposes.

Communication constructs such as ports, propagators, cells, nets, transports, contexts, and lambdas are not kernel entities with global identity. They construct words and messages whose verbs close over local machinery. Stable message-handling behavior can be interpreted as entity-like, but entity-ness is not built into the model.

**The kernel rejects privilege, not existence.** Identity, schemas, consensus, lifecycle, peers, sessions, objects, and protocols can exist as opt-in constructs in std or user code. They are not forced into the foundation.

## Read This First

**Before touching kernel or std code, read [book.org](book.org).** It is the authored source for the kernel and the model. Most std choices look unmotivated without `book.org` and obvious with it.

## Active Structure

**Active, on-philosophy:**

- [packages/core](packages/core) - the kernel. The literate document [book.org](book.org) tangles the kernel section to [src/bassline.js](packages/core/src/bassline.js). It defines `Word`/`word`, `Msg`/`msg`, noun/verb factories, and the minimal recognition vocabulary around them.

- [packages/std](packages/std) - standard library on top of the kernel. It is downstream of the model, not part of the kernel's claim.
  - [src/wire.js](packages/std/src/wire.js) - `mold` lowers a Msg to JSON-safe data (parking each cap via `mintId`); `load` is the inverse (binding ids back to live caps via `resolveId`). The closure-to-data half of the reify-to-travel bridge.
  - [src/context.js](packages/std/src/context.js) - `context()` is the registry that brokers between live cap closures and wire ids. Builds on `wire.js` to provide the `conversation` and `dialogue` dialects that ferry caps across a transport. Not a peer protocol.
  - [src/lambda.js](packages/std/src/lambda.js) - message-relative `call`/`resolve`/`reject` protocol. Important showcase for multi-step protocols, progressive binding, and higher-order distributed interaction.
  - [src/shape.js](packages/std/src/shape.js) - small predicate and cap-invocation helpers.
  - [src/data/](packages/std/src/data/) - recognition predicates and data helpers. These are mainly stale, but the general concept will be useful it's just not implemented yet. It's just about the fact that messages can describe many possible interpretations of something, and these can be layered.
  - [scratch/](packages/std/scratch/) - examples and probes (`lambda.js`, `list.js`, `ski.js`, `quorum.js`). Useful for understanding affordances; not canonical API design.

**Experimental / WIP - do not use as canonical:**

- [packages/crypto](packages/crypto)

Treat these as scratch unless explicitly asked to work in one.

## Working In This Codebase

- **The kernel source of truth is [book.org](book.org); [bassline.js](packages/core/src/bassline.js) is the tangled output.** The two stay in sync via org-babel: changes to `book.org` tangle out to `bassline.js`, and `bassline.js` carries `// [[file:...::*Section]]` markers so changes there can be detangled back into `book.org`. Edits to either side work as long as the markers stay intact, but the prose and structure live in the org file — prefer editing there when a change is more than a small in-section tweak. Either way, Claude should not be editing the kernel without an explicit instruction; surface proposed changes to the user instead.
- Each line of the kernel is extremely load-bearing and meticulously designed. Seemingly small changes can have dramatic effects on the invariants std and apps rely on. Treat it as read-only and route proposed changes through the user.
- Std modules are downstream of `book.org`'s definitions. When critiquing std, first decide whether the issue is the std choice or the kernel axiom it rests on.
- Do not import mental models from other systems. Ports are not actors. Caps are not RPC. Lambdas are not serialized functions. `dialogue` is not a peer protocol. Bassline vocabulary is the vocabulary.
- Caps are message-relative ways to speak, not references to things. A cap does not assert the existence, identity, or location of a referent.
- Caps reified to travel use `loadMessage` (the wire envelope) and `via` (the dispatch key) as reserved spellings only within the `wire.js` / `context.js` dialect. The kernel reserves no wire keys.
- Lifecycle does not propagate. `close` is always a local decision; senders are not notified.
- `EOF` is a local convenience symbol, never wire data.
- Messages may be implemented as JavaScript objects, but they are not objects in the model. Entity-like behavior emerges from stable message handling and closed-over context.

## Running

```bash
pnpm install
pnpm test

# scratch examples
node packages/std/scratch/lambda.js
node packages/std/scratch/list.js
node packages/std/scratch/ski.js
node packages/std/scratch/quorum.js
```

## License

AGPLv3
