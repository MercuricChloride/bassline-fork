// Dialects: how a `block`'s source string is evaluated, keyed by its `language`
// directive. Evaluation lives outside the value space — a dialect takes a source
// string and returns a Value. Unknown languages have no dialect (the block then
// renders inert: custody without comprehension).
import type { Value } from '@bassline/core/data'
import { int, record, str, sym } from '@bassline/core/data'

export type Dialect = (source: string) => Value

const err = (msg: string): Value => record(sym('error'), str(msg))

/** A tiny RPN/Forth-ish calculator over integers: `10 20 +` -> 30. */
function forth(source: string): Value {
  const stack: bigint[] = []
  for (const tok of source.trim().split(/\s+/).filter(Boolean)) {
    if (/^[+-]?\d+$/.test(tok)) {
      stack.push(BigInt(tok))
      continue
    }
    const b = stack.pop()
    const a = stack.pop()
    if (a === undefined || b === undefined)
      return err(`stack underflow at '${tok}'`)
    switch (tok) {
      case '+':
        stack.push(a + b)
        break
      case '-':
        stack.push(a - b)
        break
      case '*':
        stack.push(a * b)
        break
      case '/':
        stack.push(b === 0n ? 0n : a / b)
        break
      default:
        return err(`unknown word '${tok}'`)
    }
  }
  const top = stack.pop()
  return top === undefined ? err('empty result') : int(top)
}

export const DIALECTS: Record<string, Dialect> = { forth }

export const dialectFor = (lang: string | undefined): Dialect | undefined =>
  lang ? DIALECTS[lang] : undefined
