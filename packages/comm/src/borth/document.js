//@ts-check
// Recognition of the borth document forms and the finders that pull them out of
// a document. All pure: a borth document is an ordinary bassline document whose
// first form is `(lang borth); the rest of borth is a consumer of these.
/** @import {Value, Values} from "@bassline/core/data" */

/**
 * @typedef {Values['record'] & {head: Values['symbol'], fields: [Values['symbol']]}} LangDirective
 */

/**
 * @param {Value} v
 * @param {string} langName
 * @returns {v is LangDirective}
 */
function isLangDirective(v, langName) {
  if (!(v.actionable && v.kind === 'record')) return false
  const [head, lang] = [v.head, v.fields[0]]
  if (!(head.kind === 'symbol' && head.value === 'lang')) return false
  if (!(lang.kind === 'symbol' && lang.value === langName)) return false
  return true
}

/**
 * An actionable record whose head is the given spelling.
 * @param {Value} v
 * @param {string} head
 * @returns {v is Values['record'] & {head: Values['symbol']}}
 */
function isHeaded(v, head) {
  return (
    v.actionable &&
    v.kind === 'record' &&
    v.head.kind === 'symbol' &&
    v.head.value === head
  )
}

/** @param {Value} v @returns {v is Values['record'] & {head: Values['symbol']}} */
export const isBorthExpression = v => isHeaded(v, 'borth')

/** @param {Value} v @returns {v is Values['record'] & {head: Values['symbol']}} */
export const isDefDirective = v => isHeaded(v, 'def')

/** @param {Value} v @returns {v is Values['record'] & {head: Values['symbol']}} */
export const isStackDirective = v => isHeaded(v, 'stack')

/**
 * @param {Value[]} doc
 * @returns {doc is [LangDirective, ...Value[]]}
 */
export function isBorthDocument(doc) {
  return isLangDirective(doc[0], 'borth')
}

/**
 * Every `(def {…})` block.
 * @param {Value[]} doc
 * @yields {Values['record']}
 */
export function* findDefs(doc) {
  for (const val of doc.slice(1)) {
    if (isDefDirective(val)) yield val
  }
}

/**
 * The first `(stack …)` block, if any. Its fields are the initial stack,
 * bottom-to-top (leftmost is the bottom).
 * @param {Value[]} doc
 * @returns {(Values['record'] & {head: Values['symbol']}) | undefined}
 */
export function findStack(doc) {
  for (const val of doc.slice(1)) {
    if (isStackDirective(val)) return val
  }
  return undefined
}

/**
 * Every `(borth …)` block, in document order.
 * @param {Value[]} doc
 * @yields {Values['record']}
 */
export function* findBorthExpressions(doc) {
  for (const val of doc.slice(1)) {
    if (isBorthExpression(val)) yield val
  }
}
