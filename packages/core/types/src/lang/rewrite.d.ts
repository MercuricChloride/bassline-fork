/**
 * Rewrite a value tree with a rule, bottom-up. Children are rewritten first,
 * the node is rebuilt, then the rule is applied; if the rule changed the node
 * (by canonical-encoding equality) the result is rewritten again, to a fixpoint.
 * @param {Value} v
 * @param {(node: Value) => Value} rule
 * @param {{ fixpoint?: boolean, maxSteps?: number }} [opts]
 */
export function rewrite(v: Value, rule: (node: Value) => Value, opts?: {
    fixpoint?: boolean;
    maxSteps?: number;
}): Value;
/**
 * Try each rule in order; the first that changes the node is returned, or the original node if none do.
 * @param {...((node: Value) => Value)} rs
 * @returns {(node: Value) => Value}
 */
export function rules(...rs: ((node: Value) => Value)[]): (node: Value) => Value;
import type { Value } from '../data.js';
//# sourceMappingURL=rewrite.d.ts.map