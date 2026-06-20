// Collection: a node gathers its own directives from its child stream.
//
// A child is a DIRECTIVE if it carries the actionable mark, otherwise it is
// CONTENT. There is deliberately NO merge: directives are handed back as an
// ordered list of standalone "messages". A node that wants merge-like behavior
// folds the list itself (see firstOf/lastOf) — no global settings policy.
import type { Value } from '@bassline/core/data'
import { kind } from '@bassline/core/match'
import { at, sk } from './match'

const atName = (name: string) => at(sk(name))

export interface Collected {
  /** Actionable children, in document order. Each is a standalone message. */
  directives: Value[]
  /** Everything else, in document order. */
  content: Value[]
}

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
    ;(child.actionable ? directives : content).push(child)
  }
  return { directives, content }
}

// ---- Optional folds a node MAY opt into (not imposed) -----------------------

/** First directive for which `pick` yields a value -> that value. */
export function firstOf(
  directives: Value[],
  pick: (v: Value) => Value | undefined
): Value | undefined {
  for (const d of directives) {
    const found = pick(d)
    if (found !== undefined) return found
  }
  return undefined
}

/** Last directive for which `pick` yields a value -> that value. */
export function lastOf(
  directives: Value[],
  pick: (v: Value) => Value | undefined
): Value | undefined {
  let result: Value | undefined
  for (const d of directives) {
    const found = pick(d)
    if (found !== undefined) result = found
  }
  return result
}

/** Convenience: first directive carrying symbol key `name` -> its value. */
export const firstKey = (directives: Value[], name: string) =>
  firstOf(directives, atName(name))

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
