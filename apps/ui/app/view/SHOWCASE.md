# What the bassline document format is actually good at

These notes accompany the example documents in [`public/examples`](../../public/examples) and the renderer in this folder. The question is not "can it draw a UI" — anything can draw a UI. The question is what this format buys you that HTML+JS, JSON(+schema), Markdown, Jupyter, JSX, or a spreadsheet do not. Each example below foregrounds one distinct merit, and each is backed by a test in [`examples.test.tsx`](examples.test.tsx).

The whole renderer is ~7 small files. A node is just a `record`: `<head {directives…} …content>`. A child is **content** unless it carries the actionable mark, in which case it is a **directive** the node collects for itself. That is the entire model.

---

## 1. `report.blt` — the document, the program, and the data are one value

The quarter total is written as `` `<block `{language: "forth"} "120 90 + 75 +"> `` — not as the number `285`. The source that produces the figure travels _inside_ the document. Run it and a `` `{results: 285} `` directive is appended, producing a new document value in which source and result sit side by side. Document → program → document, with no boundary crossed.

**Why this is better than the usual stack:**

- **HTML + JS + JSON + a template engine** is _four_ languages with three boundaries (markup vs script vs data vs template). The figure, the code that computes it, and the data it reads live in different files and different grammars. Here they are one value in one grammar.
- **A spreadsheet** shows you `285` and hides `=120+90+75` behind a click; the formula is not part of the cell's value, it is engine state. Bassline keeps the program _as content_ — you can see it, diff it, send it, and re-run it.
- **A function call** in ordinary code discards its source the moment it returns. Here evaluation is additive: the result is appended _beside_ the source, so the artifact stays self-describing and re-derivable.
- Because a document is just a `Value` with a canonical encoding, two structurally identical subtrees _are the same value_ (equal CE bytes) — they cache, dedupe, and memoize for free. No format that distinguishes "the JSON" from "the AST" from "the wire bytes" can say that.

---

## 2. `untrusted.blt` — custody without comprehension (the mark)

This document arrives from a stranger and carries programs in forth, python, and sql. The renderer **runs nothing on load**. It offers to run the forth block (because it happens to speak forth) and holds the python and sql blocks _inert_ — visible, inspectable, never executed.

The reason it can do this safely with zero knowledge of those languages is that "this is an instruction" is a **grammatical bit** (the actionable mark), not a convention you have to understand. A participant can hold, store, forward, diff, and even render a document full of code it cannot or will not run, and always know which parts are speech and which are instruction.

**Why this is better:**

- **HTML** runs `<script>` _by default_ the instant the page is parsed. Safety is opt-out (sanitizers, CSP) and historically the source of an entire class of XSS bugs. Bassline inverts it: execution is opt-_in_ and grammatically fenced.
- **JSON** cannot even express "this fragment is code" — code smuggled through JSON is just a string, indistinguishable from data until some out-of-band rule decides to `eval` it. The mark makes the distinction first-class and visible to everyone.
- **A notebook** stores code cells as strings whose code-ness is a property of the _container format_ (`"cell_type": "code"`), not of the value — and the kernel that runs them is ambient, stateful, and trusted. Here the source is a value, its instruction-ness is intrinsic, and the evaluator is a local choice per node.

This is the cleavage the format is really built around: **custody is free, but comprehension costs vocabulary** — and the two are decoupled.

---

## 3. `recipe.blt` — partial recognition, graceful degradation, no schema

The document uses a domain vocabulary the renderer has never heard of: `recipe`, `ingredient`, `step`. None are in the vocab table. They render anyway — through the generic fallback — as labeled, inspectable nodes with their directives (`{serves: 4}`, `{amount: "200g"}`) intact, while the standard `heading` and `text` inside render richly. A recipe-aware renderer would lay the _same value_ out as a card with a checklist. Same document, deeper reading.

**Why this is better:**

- **JSON Schema / protobuf / typed configs** reject unknown fields or demand a migration. An unrecognized shape is an _error_. Here it is an _opportunity_: recognition is additive and layered, never gating.
- **`{ "type": "ingredient" }` discriminators** require shared vocabulary on both ends; at a zero-vocabulary boundary they evaporate into noise. The record _head_ is grammatical tagging — a generic tool separates head / directives / content with no vocabulary at all, then richer tools recognize more.
- **React / component frameworks** throw or render nothing for an unregistered component, and a prop of the wrong type is a crash. Here a node reads only the directives it recognizes and ignores the rest, so the document and the renderer can evolve independently.
- **Markdown** degrades gracefully too, but it is _flat_ — it cannot carry typed, nested, structured domain data with its own sub-vocabularies. Bassline degrades gracefully _and_ keeps full structure.

This is partial-information programming: build the richest local understanding you can from what you have, act on it, and let the rest pass through untouched.

---

## The through-line

| Merit | Bassline | The usual alternative |
| --- | --- | --- |
| One substrate for doc / program / data | one `Value`, one grammar | HTML+JS+JSON+template; AST ≠ wire ≠ file |
| Code vs content distinction | grammatical mark, opt-in eval | HTML `<script>` runs by default; JSON can't say it |
| Identity / caching | canonical bytes = identity, value equality | text diffs; no structural identity |
| Unknown shapes | render via fallback, additive recognition | schema rejection / crash / migration |
| Tagging | zero-vocab record head | `{type:}` needs shared vocabulary |
| Computation results | appended beside source, re-derivable | hidden engine state (spreadsheet) / discarded (call) |
| Many views of one value | UI, DataView, printed text, bytes — all of one `Value` | format dictates one interpretation |

## What is _not_ special (kept honest)

The mark makes _not understanding safe_; it does not make understanding cheap — a recipe-aware layout still has to be written. The format gives you a clean substrate and an honest floor for distribution and trust; it does not hand you the rich vocabularies for free. That is the right trade: the floor is universal and the richness is local and opt-in.
