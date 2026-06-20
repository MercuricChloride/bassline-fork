/**
 * @param {...[Predicate, (aNode: Value) => Value]} cases
 * @returns {(aNode: Value) => Value}
 */
export function match(...cases: [Predicate, (aNode: Value) => Value][]): (aNode: Value) => Value;
export namespace kind {
    let nil: Guard<Values["nil"]>;
    let bool: Guard<Values["bool"]>;
    let int: Guard<Values["int"]>;
    let float: Guard<Values["float"]>;
    let string: Guard<Values["string"]>;
    let symbol: Guard<Values["symbol"]>;
    let bytes: Guard<Values["bytes"]>;
    let list: Guard<Values["list"]>;
    let dict: Guard<Values["dict"]>;
    let record: Guard<Values["record"]>;
    let set: Guard<Values["set"]>;
}
export function and(...preds: Predicate[]): Predicate;
export function or(...preds: Predicate[]): Predicate;
/** @type {(p: Predicate) => Predicate} */
export const not: (p: Predicate) => Predicate;
export const frame: Predicate;
/** @type {Predicate} */
export const actionable: Predicate;
export const passive: Predicate;
export function any(): boolean;
/** @type {(name: string) => Predicate} */
export const spelled: (name: string) => Predicate;
/** @type {(p: Predicate) => Predicate} */
export const head: (p: Predicate) => Predicate;
/** @type {(p: Predicate, f: (aNode: Value) => Value) => (aNode: Value) => Value} */
export const rule: (p: Predicate, f: (aNode: Value) => Value) => (aNode: Value) => Value;
export type Guard<T extends Value> = (x: Value) => x is T;
export type Predicate = (x: Value) => boolean;
import type { Value } from "./data.js";
import type { Values } from "./data.js";
//# sourceMappingURL=match.d.ts.map