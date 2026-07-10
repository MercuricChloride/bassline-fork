/**
 * Yield a value and every constituent, depth-first, in document order.
 * @param {Value} v
 * @yields {Value}
 * @returns {Generator<Value, void>}
 */
export function walk(v: Value): Generator<Value, void>;
/**
 *
 * @param {Value} v
 * @yields {Atom}
 * @returns {Generator<Atom, void>}
 */
export function atoms(v: Value): Generator<Atom, void>;
/**
 * @param {Value} v
 */
export function hasActionable(v: Value): boolean;
/**
 * True when no value contains itself
 * @param {Value} v
 */
export function cycleFree(v: Value): boolean;
/**
 * The same value with the mark set as given (a shallow copy when it differs).
 * @param {Value} v
 * @param {boolean} actionable
 * @returns {Value}
 */
export function withMark(v: Value, actionable?: boolean): Value;
/**
 * @overload
 * @param {Values['dict']} v
 * @param {(x: [Value, Value]) => [Value, Value]} fn
 * @returns {Values['dict']}
 */
export function map(v: Values["dict"], fn: (x: [Value, Value]) => [Value, Value]): Values["dict"];
/**
 * @overload
 * @param {Values['list']} v
 * @param {(x: Value) => Value} fn
 * @returns {Values['list']}
 */
export function map(v: Values["list"], fn: (x: Value) => Value): Values["list"];
/**
 * @overload
 * @param {Values['set']} v
 * @param {(x: Value) => Value} fn
 * @returns {Values['set']}
 */
export function map(v: Values["set"], fn: (x: Value) => Value): Values["set"];
/**
 * @overload
 * @param {Values['record']} v
 * @param {(x: Value) => Value} fn
 * @returns {Values['record']}
 */
export function map(v: Values["record"], fn: (x: Value) => Value): Values["record"];
/**
 * The value under `key`, or undefined when the dict / set doesn't speak of it.
 * @param {Values[('dict' | 'set')]} v
 * @param {Value} key
 * @throws {TypeError} when v isn't a dict / set
 */
export function at(v: Values[("dict" | "set")], key: Value): Value;
/**
 * @overload
 * @param {Values['dict']} v
 * @param {Value} key
 * @param {Value} Value
 * @returns {Values['dict']}
 */
export function assoc(v: Values["dict"], key: Value, Value: Value): Values["dict"];
/**
 * @overload
 * @param {Values['set']} v
 * @param {Value} value
 * @returns {Values['set']}
 */
export function assoc(v: Values["set"], value: Value): Values["set"];
export function isData(v: Value): boolean;
export function isActionable(v: Value): boolean;
import type { Value } from './forms.js';
import type { Atom } from './forms.js';
import type { Values } from './forms.js';
//# sourceMappingURL=ops.d.ts.map