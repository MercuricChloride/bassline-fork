// Symbol completion: the bare symbols already present in a document. Parses with
// the canonical reader, so only real symbols are collected (not string contents
// or numbers). Pure and vscode-free; extension.ts caches the last successful
// parse and reuses it while the document is mid-edit and unparseable.
import { read } from '@bassline/core/text'
import { walk } from '@bassline/core/data'

const DELIM = new Set([...' \t\n\r,[]{}<>():#\'"`'])

/** Whether a symbol can be written bare (so inserting it produces valid text). */
function bareSafe(s: string): boolean {
  if (s.length === 0 || /[0-9]/.test(s[0])) return false
  for (const c of s) if (DELIM.has(c)) return false
  return true
}

/** Distinct bare symbols in the document, or null when it does not parse. */
export function symbolsIn(text: string): string[] | null {
  let roots
  try {
    roots = read(text)
  } catch {
    return null
  }
  const out = new Set<string>()
  for (const root of roots) {
    for (const node of walk(root)) {
      if (node.kind === 'symbol' && bareSafe(node.value)) out.add(node.value)
    }
  }
  return [...out]
}
