// Directive recognition. A form is a directive when it carries the actionable
// mark and is a record or dict (the rule from apps/ui/app/view/collect.ts). A
// record's head spelling selects the affordance kind; a dict — itself, or the
// first dict field of a record — carries the named parameters.
import type { Value, Values } from '@bassline/core/data'
import { fresh } from '@bassline/core/data'

/** A directive is an actionable record or dict. */
export function isDirective(v: Value): v is Values['record'] | Values['dict'] {
  return (v.kind === 'record' || v.kind === 'dict') && v.actionable
}

/** The head spelling of a record, or undefined if the head is not a symbol. */
export function headSpelling(v: Value): string | undefined {
  if (v.kind !== 'record') return undefined
  const h = v.head
  return h.kind === 'symbol' ? h.value : undefined
}

/**
 * A comment is an actionable `<comment "…">` directive: an instruction to the
 * consumer to drop it. Consumers that serialize or evaluate filter these out;
 * the formatter preserves them.
 */
export function isComment(v: Value): boolean {
  return v.actionable && headSpelling(v) === 'comment'
}

// Cache symbol keys so repeated dict lookups stay cheap (cf. view match.ts `sk`).
const symKeys = new Map<string, Value>()
function sk(name: string): Value {
  let s = symKeys.get(name)
  if (!s) {
    s = fresh.symbol(name)
    symKeys.set(name, s)
  }
  return s
}

/**
 * The parameter dict of a directive: the dict itself if the directive is a
 * dict, else the first dict field of a record. Undefined when there is none.
 */
export function paramsOf(v: Value): Value | undefined {
  if (v.kind === 'dict') return v
  if (v.kind === 'record') return v.fields.find(f => f.kind === 'dict')
  return undefined
}

/** Look a named param up in a dict by its symbol key. */
export function at(params: Value | undefined, name: string): Value | undefined {
  if (!params || params.kind !== 'dict') return undefined
  return params.get(sk(name))
}

// ---- Boundary converters: Value -> JS primitive, only at the JS edge --------

export const asString = (v: Value | undefined): string | undefined =>
  v && v.kind === 'string'
    ? v.value
    : v && v.kind === 'symbol'
      ? v.value
      : undefined

export const asNumber = (v: Value | undefined): number | undefined =>
  v && v.kind === 'int'
    ? Number(v.value)
    : v && v.kind === 'float'
      ? v.value
      : undefined

export const asBool = (v: Value | undefined): boolean | undefined =>
  v && v.kind === 'bool' ? v.value : undefined
