# bassline-text

VS Code support for the bassline text syntax (`.bl`). Parsing uses `@bassline/core` (`read`); the extension adds no separate parser.

## Features

- Syntax highlighting via a TextMate grammar ([`syntaxes/bassline.tmLanguage.json`](syntaxes/bassline.tmLanguage.json)): comments (`;`), strings, quoted symbols, bytestrings (`0x…`), numbers, `nil`, record heads, and the mark (`!`).
- Diagnostics: each edit runs `read`; a `ReaderError` is shown as one squiggle at its line/column.
- Bracket auto-close, surround, and matching for `[] {} () "" ''`, and `;` line comments ([`language-configuration.json`](language-configuration.json)).

## Layout

| File | Role |
| --- | --- |
| [`src/extension.ts`](src/extension.ts) | Activation; registers diagnostics. |
| [`src/diagnostics.ts`](src/diagnostics.ts) | Reader-error diagnostics. |
| [`syntaxes/bassline.tmLanguage.json`](syntaxes/bassline.tmLanguage.json) | TextMate grammar. |
| [`language-configuration.json`](language-configuration.json) | Comments, brackets, word pattern. |

## Development

From the monorepo root:

```bash
pnpm install
pnpm --filter bassline-text build       # bundle to dist/extension.js
pnpm --filter bassline-text watch       # rebuild on change
pnpm --filter bassline-text typecheck   # tsc --noEmit
```

Press **F5** to launch an Extension Development Host, or run:

```bash
code --extensionDevelopmentPath=packages/bassline-text-vscode packages/bassline-text-vscode/examples
```

[`esbuild.mjs`](esbuild.mjs) bundles `@bassline/core` into `dist/extension.js`; `vscode` is external.
