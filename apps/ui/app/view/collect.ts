// Collection: a node gathers its own directives from its child stream.
//
// A child is a DIRECTIVE if it carries the actionable mark, otherwise it is
// CONTENT. There is deliberately NO merge: directives are handed back as an
// ordered list of standalone "messages". A node folds them itself via a
// recognition table (see consume.ts `recognize`) — no global settings policy.
import type { Value } from '@bassline/core/data'
import { kind } from '@bassline/core/match'

export interface Collected {
  /** Actionable children, in document order. Each is a standalone message. */
  directives: Value[]
  /** Everything else, in document order. */
  content: Value[]
}

/**
 * A directive is an actionable dict or record (config / command about the node).
 * An actionable *symbol* is NOT a directive — it is a reference (`` `foo ``),
 * which is content that resolves to a value. Inert values are always content.
 */
const isDirective = (v: Value) =>
  v.actionable && (kind.dict(v) || kind.record(v))

/**
 * Partition a record's direct children into directives and content. Strictly
 * direct children only — collection is local; nested directives belong to
 * nested nodes.
 */
export function collect(node: Value): Collected {
  if (!kind.record(node)) return { directives: [], content: [] }
  const directives: Value[] = []
  const content: Value[] = []
  for (const child of node.fields) {
    ;(isDirective(child) ? directives : content).push(child)
  }
  return { directives, content }
}

// ---- Boundary converters: Value -> JS primitive, ONLY at the Mantine edge ---

export const asString = (v: Value | undefined): string | undefined =>
  v && kind.string(v) ? v.value : undefined

export const asNumber = (v: Value | undefined): number | undefined =>
  v && kind.int(v) ? Number(v.value) : v && kind.float(v) ? v.value : undefined

export const asBool = (v: Value | undefined): boolean | undefined =>
  v && kind.bool(v) ? v.value : undefined

/** Symbol value as a JS string (e.g. for variant/size tokens). */
export const asToken = (v: Value | undefined): string | undefined =>
  v && kind.symbol(v) ? v.value : v && kind.string(v) ? v.value : undefined
