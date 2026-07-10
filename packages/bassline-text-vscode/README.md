# bassline-text

VS Code support for the bassline text format (`.blt`). Parsing and printing use `@bassline/core` (`read`, `readSpans`, `print`); the extension adds no separate parser.

## Features

- Syntax highlighting via a TextMate grammar ([`syntaxes/bassline-text.tmLanguage.json`](syntaxes/bassline-text.tmLanguage.json)).
- Bracket auto-close, surround, and matching for `[] {} () #{ } #[ ] "" ''` ([`language-configuration.json`](language-configuration.json)). Records are `(head …)`; `<` and `>` are ordinary symbol characters.
- Diagnostics: each edit runs `read`; a `ReaderError` is shown as one squiggle at its line/column.
- Formatting via `print`; width is `bassline.formatWidth` (default 72).
- Semantic tokens: `` `(comment "…")`` is colored as a comment.
- CodeLens: _Run…_ and _Format_ at the top of the document, _Evaluate_ (all) on documents that open with `` `(lang borth)``, one lens per recognized top-level directive, and _Evaluate_ on each individual `` `(borth …)`` block.
- Structural editing: slurp and barf, forward and backward, over lists, sets, records, and dicts.
- Completion: the bare symbols already present in the document.
- Evaluation: a document opening with `` `(lang borth)`` is a portable REPL. `` `(def {name: [quote] …})`` blocks bind words, `` `(stack …)`` seeds the stack, and `` `(borth …)`` blocks evaluate in order (`@bassline/comm`). Only the `` `(stack …)`` form is rewritten with the final stack; the `` `(borth …)`` blocks stay, so each evaluation runs them again from the new stack. A block's own _Evaluate_ lens runs just that block (a REPL step). See [borth words](#borth-words).

## Affordances and directives

Commands beyond the static set come from a provider of named affordances ([`src/affordances.ts`](src/affordances.ts)), registered two ways:

- Built-ins, registered in code (`format`).
- Kinds, registered for a directive head and instantiated by a document. An actionable record `` `(head {…})`` whose head names a kind adds an affordance.

A document is loaded into the provider from the workspace manifest (`bassline.config.blt`, on activation) or via _Load Affordances from Document…_. Provider affordances appear in _Run Command…_, and directives present in the open document appear as CodeLens.

| Directive | Effect |
| --- | --- |
| `` `(comment "…")`` | Dropped by `export`, kept by the formatter. Registers no command. |
| `` `(export {name: "…" path: "…"})`` | Writes the document's encoded values to a workspace-relative path. |
| `` `(endpoint {name: "…" host: "…" port: N})`` | Sends the document's encoded values to a TCP socket. |

## borth words

borth is a concatenative (stack) language for manipulating bassline values (`@bassline/comm`). Quotations are lists `[…]` run by combinators; a bare symbol runs the word it names, so to put a _symbol_ on the stack as data use `"name" as-symbol` (or pull one out of a literal, e.g. `keys`). Operators avoid the text delimiters `( ) : #`, so the orderings are `lt`/`gt`/`le`/`ge`.

| Category | Words |
| --- | --- |
| Stack | `dup drop swap over rot nip 2dup dupd` |
| Arithmetic | `+ - * / mod neg abs min max` (int stays int; any float → float) |
| Comparison / logic | `= ne lt gt le ge not and or` (`=`/`ne` structural; falsy = `false`/`nil`) |
| Combinators | `call dip if keep times` |
| Collections | `each map filter fold length empty?` (over list / set / dict; quote runs per element) |
| Recognition | `kind`, `int? float? string? symbol? bool? nil? bytes? list? dict? record? set?`, `number? data?` |
| The mark | `marked? mark open` |
| Sequence access | `at first last rest push concat as-list` |
| Records | `head fields record` |
| Dicts / sets | `get assoc keys values has dict set` |
| Atoms | `str-concat as-string as-symbol` |

A runtime failure (underflow, type mismatch, unbound word) pushes an inert `` `(error tag …)`` value onto the stack and halts evaluation.

## Limitations

- `endpoint` connects, writes the encoded values, and closes. It requires a listener on the port. No handshake, response, discovery, or retry.
- `export` writes concatenated canonical encodings to the local filesystem. No other formats.
- CodeLens covers top-level directives and `` `(borth …)`` blocks only.
- Semantic tokens cover comments only.
- Completion offers document symbols only; no directive heads, parameter keys, or borth words.
- Evaluation is borth-only; it rewrites only the `` `(stack …)`` form (or appends one) and leaves every other form untouched. Because the `` `(borth …)`` blocks are kept and the stack is the seed, re-evaluating re-applies them. A runtime failure pushes an `` `(error tag …)`` value and halts; later blocks do not run. No other `(lang …)` evaluators.
- Not implemented: hover, document symbols, definition, rename, `url`/DocumentLink, webview editing.

## Commands and keybindings

| Command | ID | Default key |
| --- | --- | --- |
| Format Document | `bassline.format` | — |
| Evaluate Document | `bassline.evaluate` | — |
| Run Command… | `bassline.run` | — |
| Load Affordances from Document… | `bassline.loadAffordances` | — |
| Reload Workspace Manifest | `bassline.reloadManifest` | — |
| Slurp Forward | `bassline.slurpForward` | `ctrl+alt+right` |
| Barf Forward | `bassline.barfForward` | `ctrl+alt+left` |
| Slurp Backward | `bassline.slurpBackward` | `ctrl+alt+shift+left` |
| Barf Backward | `bassline.barfBackward` | `ctrl+alt+shift+right` |

Keybindings apply only when a `bassline-text` editor is focused. `bassline.runDirective` is invoked by CodeLens; it has no keybinding or palette entry.

## Settings

- `bassline.manifest` — manifest path loaded on activation (default `bassline.config.blt`).
- `bassline.formatWidth` — formatter width (default `72`).

## Layout

| File | Role |
| --- | --- |
| [`src/extension.ts`](src/extension.ts) | Activation; registers the provider, commands, and language-feature providers. |
| [`src/affordances.ts`](src/affordances.ts) | The provider: `offer`, `kind`, `load`, `resolve`. |
| [`src/directives.ts`](src/directives.ts) | Directive recognition and parameter extraction. |
| [`src/builtins.ts`](src/builtins.ts) | `format` affordance; `export` and `endpoint` kinds. |
| [`src/paredit.ts`](src/paredit.ts) | Structural edits (slurp/barf), pure `(text, offset) → edit`. |
| [`src/format.ts`](src/format.ts) | Formatter over `print`. |
| [`src/diagnostics.ts`](src/diagnostics.ts) | Reader-error diagnostics. |
| [`src/codelens.ts`](src/codelens.ts) | Document and per-form lenses. |
| [`src/semanticTokens.ts`](src/semanticTokens.ts) | Comment tokens. |
| [`src/completion.ts`](src/completion.ts) | `symbolsIn`: bare symbols in a document. |
| [`src/util.ts`](src/util.ts) | `fullRange`. |

## Development

From the monorepo root:

```bash
pnpm install
pnpm --filter bassline-text build      # bundle to dist/extension.js
pnpm --filter bassline-text watch       # rebuild on change
pnpm --filter bassline-text test        # vitest
pnpm --filter bassline-text typecheck   # tsc --noEmit
```

Press **F5** to launch an Extension Development Host (the repo-root [`.vscode/launch.json`](../../.vscode/launch.json) targets this package and opens [`examples/`](examples)), or run:

```bash
code --extensionDevelopmentPath=packages/bassline-text-vscode packages/bassline-text-vscode/examples
```

[`esbuild.mjs`](esbuild.mjs) bundles `@bassline/core` and `@bassline/comm` into `dist/extension.js`; `vscode` is external.
