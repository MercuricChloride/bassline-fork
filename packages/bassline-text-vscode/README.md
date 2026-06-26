# bassline-text

VS Code support for the bassline text format (`.blt`). Parsing and printing use `@bassline/core` (`read`, `readSpans`, `print`); the extension adds no separate parser.

## Features

- Syntax highlighting via a TextMate grammar ([`syntaxes/bassline-text.tmLanguage.json`](syntaxes/bassline-text.tmLanguage.json)).
- Bracket auto-close, surround, and matching for `[] {} <> #{ } #[ ] "" ''` ([`language-configuration.json`](language-configuration.json)). `(` `)` are omitted; they are a syntax error in bassline.
- Diagnostics: each edit runs `read`; a `ReaderError` is shown as one squiggle at its line/column.
- Formatting via `print`; width is `bassline.formatWidth` (default 72).
- Semantic tokens: `` `<comment "…">`` is colored as a comment.
- CodeLens: _Run…_ and _Format_ at the top of the document, plus one lens per recognized top-level directive.
- Structural editing: slurp and barf, forward and backward, over lists, sets, records, and dicts.
- Completion: the bare symbols already present in the document.

## Affordances and directives

Commands beyond the static set come from a provider of named affordances ([`src/affordances.ts`](src/affordances.ts)), registered two ways:

- Built-ins, registered in code (`format`).
- Kinds, registered for a directive head and instantiated by a document. An actionable record `` `<head {…}>`` whose head names a kind adds an affordance.

A document is loaded into the provider from the workspace manifest (`bassline.config.blt`, on activation) or via _Load Affordances from Document…_. Provider affordances appear in _Run Command…_, and directives present in the open document appear as CodeLens.

| Directive | Effect |
| --- | --- |
| `` `<comment "…">`` | Dropped by `export`, kept by the formatter. Registers no command. |
| `` `<export {name: "…" path: "…"}>`` | Writes the document's encoded values to a workspace-relative path. |
| `` `<endpoint {name: "…" host: "…" port: N}>`` | Sends the document's encoded values to a TCP socket. |

## Limitations

- `endpoint` connects, writes the encoded values, and closes. It requires a listener on the port. No handshake, response, discovery, or retry.
- `export` writes concatenated canonical encodings to the local filesystem. No other formats.
- CodeLens covers top-level directives only.
- Semantic tokens cover comments only.
- Completion offers document symbols only; no directive heads or parameter keys.
- No `evaluate` affordance: the core evaluator is being replaced and will return as one `provider.offer`.
- Not implemented: hover, document symbols, definition, rename, `url`/DocumentLink, webview editing.

## Commands and keybindings

| Command | ID | Default key |
| --- | --- | --- |
| Format Document | `bassline.format` | — |
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
