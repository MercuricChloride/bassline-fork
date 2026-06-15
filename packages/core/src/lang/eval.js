// A small stateful evaluator over bassline values.
//
// The actionable bit is a *forward declaration* — "this is to be evaluated" —
// not a permission gate. Everything is data and `ctx.eval` may be applied to
// anything; the evaluator just honors the declaration: it reduces actionable
// nodes and passes static data through untouched. Two consequences fall out:
// quoting is simply stripping the bit (`toStatic`), and evaluating pure data is
// the identity (no actionable subterms ⇒ nothing happens).
//
// Records are the verb-headed programs: an actionable `<head …>` dispatches to
// handlers[head] which receives the *raw* record (unevaluated fields) plus a
// context and decides what to evaluate (vau-style) — so `define`/`if`/`quote`
// are ordinary handlers. An actionable symbol is a variable reference. State is
// an environment carried on the evaluator instance across `send` calls.

import { children, rebuild } from './rewrite.js'
import {
  BasslineRecord,
  BasslineSymbol,
  BasslineList,
  BasslineDict,
  BasslineSet,
} from '../data.js'

const isFrame = v =>
  v instanceof BasslineList ||
  v instanceof BasslineDict ||
  v instanceof BasslineRecord ||
  v instanceof BasslineSet

/**
 * Build a stateful evaluator.
 * @param {{ records?: Record<string, (record, ctx) => any>, symbol?: (symbol, ctx) => any }} handlers
 * @param {Map<string, any>} [state] the environment, carried across sends
 * @returns {{ send: (v) => any, eval: (v) => any, state: Map<string, any> }}
 */
export function evaluator(handlers = {}, state = new Map()) {
  const records = handlers.records ?? {}
  const onSymbol =
    handlers.symbol ??
    (symbol => {
      if (!state.has(symbol.value))
        throw new Error('unbound symbol: ' + symbol.value)
      return state.get(symbol.value)
    })

  const ctx = { state, eval: ev }

  function ev(v) {
    if (v.actionable) {
      if (v instanceof BasslineRecord) {
        const head = v.head
        if (!(head instanceof BasslineSymbol))
          throw new Error('actionable record head must be a symbol to dispatch')
        const handler = records[head.value]
        if (!handler) throw new Error('no evaluator handler for: ' + head.value)
        return handler(v, ctx)
      }
      if (v instanceof BasslineSymbol) return onSymbol(v, ctx)
      // an actionable list/dict/set has no verb head: reduce its contents
      if (isFrame(v)) return rebuild(v, children(v).map(ev))
      // an actionable literal evaluates to the literal itself
      return v.toStatic()
    }
    // static data: frames recurse so actionable subterms splice in place
    if (isFrame(v)) return rebuild(v, children(v).map(ev))
    return v
  }

  return { state, eval: ev, send: ev }
}
