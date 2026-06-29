/**
 * @template [T=Value]
 * @param {{[K in ValueKind]?: (value: Values[K]) => T}} handlers
 * @param {(v: Value) => T} fallback
 * @returns {(v: Value) => T}
 */
export function generic<T = Value>(handlers: { [K in ValueKind]?: (value: Values[K]) => T; }, fallback?: (v: Value) => T): (v: Value) => T;
/**
 * @param {Value} v
 */
export function hasActionable(v: Value): boolean;
/**
 * @param {Value} v
 */
export function cycleFree(v: Value): boolean;
/**
 * @param {Value} v
 * @returns {Uint8Array}
 */
export function encode(v: Value): Uint8Array;
/** @param {Uint8Array} bytes */
export function decode(bytes: Uint8Array): Value;
/** @param {Uint8Array} bytes */
export function decodeAll(bytes: Uint8Array): Value[];
/** @param {Value} v */
export function ceKey(v: Value): string;
/**
 *
 * @param {Value} a
 * @param {Value} b
 * @returns {boolean} True if a and b are equal, false otherwise
 */
export function eq(a: Value, b: Value): boolean;
/**
 * @param {unknown} x
 * @returns {x is Scalar}
 */
export function isScalar(x: unknown): x is Scalar;
/**
 * @param {unknown} x
 * @returns {x is Frame}
 */
export function isFrame(x: unknown): x is Frame;
/** @param {unknown} x */
export function isValue(x: unknown): x is Scalar | Frame;
/**
 * @param {unknown} x
 * @param {string} [msg] - The error message to throw if x is not a Bassline value
 * @throws {TypeError} if x is not a Bassline value.
 * @returns {x is Value}
 */
export function assertValue(x: unknown, msg?: string): x is Value;
export namespace fresh {
    /** @param {boolean} actionable */
    function nil(actionable?: boolean): BasslineNil;
    /**
     * @param {boolean} value
     * @param {boolean} actionable
     */
    function bool(value: boolean, actionable?: boolean): BasslineBool;
    /**
     * @param {bigint | number} value
     * @param {boolean} actionable
     */
    function int(value: bigint | number, actionable?: boolean): BasslineInt;
    /**
     * @param {number} value
     * @param {boolean} actionable
     */
    function float(value: number, actionable?: boolean): BasslineFloat;
    /**
     * @param {string} value
     * @param {boolean} actionable
     */
    function string(value: string, actionable?: boolean): BasslineString;
    /**
     * @param {string} value
     * @param {boolean} actionable
     */
    function symbol(value: string, actionable?: boolean): BasslineSymbol;
    /**
     * @param {Uint8Array} value
     * @param {boolean} actionable
     */
    function bytes(value: Uint8Array, actionable?: boolean): BasslineBytes;
    /**
     * @param {Value[]} items
     * @param {boolean} actionable
     */
    function list(items: Value[], actionable?: boolean): BasslineList;
    /**
     * @param {Value[]} aRecord
     * @param {boolean} actionable
     */
    function record(aRecord: Value[], actionable?: boolean): BasslineRecord;
    /**
     * @param {Value[]} members
     * @param {boolean} actionable
     */
    function set(members: Value[], actionable?: boolean): BasslineSet;
    /**
     * @param {Array<[Value, Value]>} entries
     * @param {boolean} actionable
     */
    function dict(entries: Array<[Value, Value]>, actionable?: boolean): BasslineDict;
}
/** @augments {ValueBase<null>} */
export class BasslineNil extends ValueBase<null, keyof ScalarValues | keyof FrameValues> {
    /**
     * @param {T} value
     * @param {boolean} actionable
     */
    constructor(value: null, actionable?: boolean);
    copy(actionable?: boolean): BasslineNil;
    /** @returns {'nil'} */
    get kind(): "nil";
}
/** @augments {ValueBase<boolean>} */
export class BasslineBool extends ValueBase<boolean, keyof ScalarValues | keyof FrameValues> {
    /**
     * @param {T} value
     * @param {boolean} actionable
     */
    constructor(value: boolean, actionable?: boolean);
    /** @returns {'bool'}*/
    get kind(): "bool";
}
/** @augments {ValueBase<bigint>} */
export class BasslineInt extends ValueBase<bigint, keyof ScalarValues | keyof FrameValues> {
    /**
     * @param {T} value
     * @param {boolean} actionable
     */
    constructor(value: bigint, actionable?: boolean);
    /** @returns {'int'}*/
    get kind(): "int";
}
/** @augments {ValueBase<number>} */
export class BasslineFloat extends ValueBase<number, keyof ScalarValues | keyof FrameValues> {
    /**
     * @param {T} value
     * @param {boolean} actionable
     */
    constructor(value: number, actionable?: boolean);
    /** @returns {'float'}*/
    get kind(): "float";
}
/** @augments {ValueBase<string>} */
export class BasslineString extends ValueBase<string, keyof ScalarValues | keyof FrameValues> {
    /**
     * @param {T} value
     * @param {boolean} actionable
     */
    constructor(value: string, actionable?: boolean);
    /** @returns {'string'}*/
    get kind(): "string";
}
/** @augments {ValueBase<string>} */
export class BasslineSymbol extends ValueBase<string, keyof ScalarValues | keyof FrameValues> {
    /**
     * @param {T} value
     * @param {boolean} actionable
     */
    constructor(value: string, actionable?: boolean);
    /** @returns {'symbol'}*/
    get kind(): "symbol";
}
/** @augments {ValueBase<Uint8Array>} */
export class BasslineBytes extends ValueBase<Uint8Array<ArrayBufferLike>, keyof ScalarValues | keyof FrameValues> {
    /**
     * @param {T} value
     * @param {boolean} actionable
     */
    constructor(value: Uint8Array<ArrayBufferLike>, actionable?: boolean);
    get value(): Uint8Array<ArrayBuffer>;
    /** @returns {'bytes'}*/
    get kind(): "bytes";
}
export class BasslineList extends SeqBase {
    /** @returns {'list'}*/
    get kind(): "list";
}
export class BasslineRecord extends SeqBase {
    get head(): Value;
    get fields(): Value[];
    /** @returns {'record'} */
    get kind(): "record";
}
/**
 * @augments {ValueBase<Map<string, Value>>}
 */
export class BasslineSet extends ValueBase<Map<string, Value>, keyof ScalarValues | keyof FrameValues> {
    /**
     * @param {T} value
     * @param {boolean} actionable
     */
    constructor(value: Map<string, Value>, actionable?: boolean);
    /** @param {Value} aValue */
    has(aValue: Value): boolean;
    /** @param {...Value} items */
    append(...items: Value[]): BasslineSet;
    get length(): number;
    get freshValue(): Value[];
    copy(actionable?: boolean): BasslineSet;
    /**
     * @param {{ (node: Value): Value; (value: Value, index: number, array: Value[]): Value; }} callback
     */
    map(callback: {
        (node: Value): Value;
        (value: Value, index: number, array: Value[]): Value;
    }): BasslineSet;
    /**
     * @param {(value: Value, index: number, array: Value[]) => value is Value} callback
     */
    filter(callback: (value: Value, index: number, array: Value[]) => value is Value): BasslineSet;
    asSeq(): BasslineList;
    get values(): BasslineList;
    /** @returns {'set'} */
    get kind(): "set";
}
/**
 * @augments {ValueBase<Map<string, [Value, Value]>>}
 */
export class BasslineDict extends ValueBase<Map<string, [Value, Value]>, keyof ScalarValues | keyof FrameValues> {
    /**
     * @param {T} value
     * @param {boolean} actionable
     */
    constructor(value: Map<string, [Value, Value]>, actionable?: boolean);
    get length(): number;
    asSeq(): BasslineList;
    /**
     * @param {Value} key
     * @param {Value} value
     */
    set(key: Value, value: Value): BasslineDict;
    /** @param {Value} key */
    get(key: Value): Value;
    /** @param {Value} key */
    has(key: Value): boolean;
    /** @param {Value} key */
    delete(key: Value): BasslineDict;
    /** @param {(value: [Value, Value], index: number, array: [Value, Value][]) => [Value, Value]} callback */
    map(callback: (value: [Value, Value], index: number, array: [Value, Value][]) => [Value, Value]): BasslineDict;
    /**
     * @param {(value: [Value, Value], index: number, array: [Value, Value][]) => boolean} callback
     */
    filter(callback: (value: [Value, Value], index: number, array: [Value, Value][]) => boolean): BasslineDict;
    get keys(): BasslineList;
    get values(): BasslineList;
    /** @returns {'dict'} */
    get kind(): "dict";
}
export const walk: any;
export function isData(v: Value): boolean;
export function isActionable(v: Value): boolean;
export const BAD_PREFIX: 0;
export const NIL_PREFIX: 1;
export const FALSE_PREFIX: 2;
export const TRUE_PREFIX: 3;
export const INT_PREFIX: 4;
export const FLOAT_PREFIX: 5;
export const STRING_PREFIX: 6;
export const SYMBOL_PREFIX: 7;
export const BYTES_PREFIX: 8;
export const LIST_PREFIX: 9;
export const DICT_PREFIX: 10;
export const RECORD_PREFIX: 11;
export const SET_PREFIX: 12;
export const valueDescriptor: (v: Value) => number;
/** @type {(tag: number, actionable: boolean) => number} */
export const descriptor: (tag: number, actionable: boolean) => number;
export function tagOf(b: number): number;
export function actionableOf(b: number): boolean;
export class BasslineDecoder {
    /**
     * @param {Uint8Array} input
     * @returns {Value}
     */
    static one(input: Uint8Array): Value;
    /**
     * @param {Uint8Array} input
     * @returns {Value[]}
     */
    static all(input: Uint8Array): Value[];
    /** @param {Uint8Array} bytes */
    constructor(bytes: Uint8Array);
    bytes: Uint8Array<ArrayBufferLike>;
    pos: number;
    readByte(): number;
    /** @param {number} n The number of bytes to read  */
    readBytes(n: number): Uint8Array<ArrayBufferLike>;
    readVarint(): number;
    /** @param {Uint8Array} b */
    decodeUtf8(b: Uint8Array): string;
    /** @param {Uint8Array} b */
    decodeF64(b: Uint8Array): number;
    /** @param {Uint8Array} b */
    decodeInt(b: Uint8Array): bigint;
    frameEnd(): number;
    /** @returns {Value} */
    decodeValue(): Value;
    /** @param {boolean} actionable */
    decodeList(actionable: boolean): BasslineList;
    /** @param {boolean} actionable */
    decodeDict(actionable: boolean): BasslineDict;
    /** @param {boolean} actionable */
    decodeRecord(actionable: boolean): BasslineRecord;
    /** @param {boolean} actionable */
    decodeSet(actionable: boolean): BasslineSet;
    /**
     * @param {number} tag
     * @param {boolean} actionable
     */
    decodeByTag(tag: number, actionable: boolean): BasslineString | BasslineSymbol | BasslineSet | BasslineDict | BasslineRecord | BasslineBytes | BasslineFloat | BasslineNil | BasslineBool | BasslineInt | BasslineList;
}
export type AltValue<V, K extends ValueKind> = {
    readonly value: V;
    readonly kind: K;
    actionable(): boolean;
    actionable(a: boolean): AltValue<V, K>;
};
export type ScalarValues = {
    nil: BasslineNil;
    bool: BasslineBool;
    int: BasslineInt;
    float: BasslineFloat;
    string: BasslineString;
    symbol: BasslineSymbol;
    bytes: BasslineBytes;
};
export type FrameValues = {
    list: BasslineList;
    dict: BasslineDict;
    record: BasslineRecord;
    set: BasslineSet;
};
export type BasslineVal<T> = {
    readonly actionable: boolean;
    readonly value: T;
    readonly kind: ValueKind;
    copy(actionable: boolean): BasslineVal<T>;
    eq(other: Value): boolean;
    encode(): Uint8Array<ArrayBuffer>;
    ceKey(): string;
};
export type Values = ScalarValues & FrameValues;
export type Scalar = ScalarValues[keyof ScalarValues];
export type Frame = FrameValues[keyof FrameValues];
export type Value = Values[keyof Values];
export type ValueKind = keyof Values;
/**
 * @template T
 * @template {keyof typeof fresh} [K=ValueKind]
 */
declare class ValueBase<T, K extends keyof typeof fresh = keyof ScalarValues | keyof FrameValues> {
    /**
     * @param {T} value
     * @param {boolean} actionable
     */
    constructor(value: T, actionable?: boolean);
    /** @private */
    private _actionable;
    /** @protected */
    protected _value: T;
    get actionable(): boolean;
    get value(): T;
    /** @returns {K} */
    get kind(): K;
    /** @returns {typeof fresh[typeof this['kind']]} */
    get fresh(): (typeof fresh)[(typeof this)["kind"]];
    encode(): Uint8Array<ArrayBufferLike>;
    ceKey(): string;
    /** @param {Value} other */
    eq(other: Value): boolean;
    /**
     * Creates a shallow copy of this value.
     * @param {boolean} [actionable] Whether the copied value should be actionable.
     * @returns {Value} A shallow copy of this value.
     */
    copy(actionable?: boolean): Value;
}
/**
 * @augments {ValueBase<Value[], 'list' | 'record'>}
 */
declare class SeqBase extends ValueBase<Value[], "record" | "list"> {
    /**
     * @param {T} value
     * @param {boolean} actionable
     */
    constructor(value: Value[], actionable?: boolean);
    get length(): number;
    /**
     * @param {number} start
     * @param {number} end
     */
    slice(start: number, end: number): BasslineRecord | BasslineList;
    /**
     * @param {(item: Value, index: number, array: Value[]) => Value} callback
     */
    map(callback: (item: Value, index: number, array: Value[]) => Value): BasslineRecord | BasslineList;
    /**
     * @param {(item: Value, index: number, array: Value[]) => boolean} callback
     */
    filter(callback: (item: Value, index: number, array: Value[]) => boolean): BasslineRecord | BasslineList;
    /**
     * @param {number} index
     */
    at(index: number): Value;
    /**
     * @param {number} index
     * @param {Value} value
     */
    set(index: number, value: Value): BasslineRecord | BasslineList;
    /**
     * @param {...Value} items
     */
    append(...items: Value[]): BasslineRecord | BasslineList;
    asSeq(): this;
    [Symbol.iterator](): Generator<Value, void, unknown>;
}
export {};
//# sourceMappingURL=data.d.ts.map