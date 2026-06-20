/**
 * @param {unknown} x
 * @param msg
 * @throws {TypeError} if x is not a Bassline value.
 * @returns {x is BasslineValue}
 */
export function assertValue(x: unknown, msg?: string): x is BasslineValue;
/**
 * @param {unknown} value
 * @returns {BasslineValue}
 */
export function toBassline(value: unknown): BasslineValue;
/**
 * Whether a value carries the actionable bit anywhere in its tree
 * @param {BasslineValue} v
 * @returns {boolean}
 */
export function hasActionable(v: BasslineValue): boolean;
/**
 * @param {BasslineValue} v
 */
export function cycleFree(v: BasslineValue): boolean;
/**
 * @param {BasslineValue} v The value to be encoded
 */
export function encode(v: BasslineValue): Uint8Array<ArrayBuffer>;
/**
 * @param {Uint8Array} bytes
 */
export function decode(bytes: Uint8Array): BasslineValue;
/**
 * @param {Uint8Array} bytes
 */
export function decodeAll(bytes: Uint8Array): BasslineValue[];
/**
 *
 * @param {BasslineValue} v
 */
export function ceKey(v: BasslineValue): string;
/**
 *
 * @param {BasslineValue} a
 * @param {BasslineValue} b
 * @returns {boolean} True if a and b are equal, false otherwise
 */
export function eq(a: BasslineValue, b: BasslineValue): boolean;
/**
 * @typedef {{
 * nil: BasslineNil
 * bool: BasslineBool
 * int: BasslineInt
 * float: BasslineFloat
 * string: BasslineString
 * symbol: BasslineSymbol
 * bytes: BasslineBytes
 * }} ScalarValues
 */
/**
 * @typedef {{
 * list: BasslineList
 * dict: BasslineDict
 * record: BasslineRecord
 * set: BasslineSet
 * }} FrameValues
 */
/** @typedef {ScalarValues & FrameValues} Values */
/** @typedef {ScalarValues[keyof ScalarValues]} Scalar */
/** @typedef {FrameValues[keyof FrameValues]} Frame */
/** @typedef {BasslineValue} Value */
/** @typedef { keyof Values } ValueKind */
/** @type {(x: unknown) => x is BasslineValue} */
export const isValue: (x: unknown) => x is BasslineValue;
export class BasslineValue {
    constructor(actionable?: boolean);
    get actionable(): boolean;
    get isFrame(): boolean;
    /** @returns {ValueKind} */
    get kind(): ValueKind;
    toStatic(): void | this;
    toActionable(): void | this;
    /**
     * @param {BasslineVisitor} _aVisitor
     */
    accept(_aVisitor: BasslineVisitor): void;
    /**
     * @param {boolean} _actionable
     */
    copy(_actionable: boolean): void;
    encode(): Uint8Array<ArrayBuffer>;
    ceKey(): string;
    /**
     *
     * @param {Value} other
     */
    eq(other: Value): boolean;
    /**
     *
     * @param {BasslineValue} other
     */
    compareBytes(other: BasslineValue): number;
    #private;
}
export class BasslineNil extends BasslineValue {
    get value(): any;
    copy(actionable?: boolean): BasslineNil;
    /**
     *
     * @template {BasslineVisitor} T
     * @param {T} aVisitor
     */
    accept<T extends BasslineVisitor>(aVisitor: T): BasslineNil;
    /** @returns {'nil'} */
    get kind(): "nil";
}
export class BasslineBool extends BasslineValue {
    /**
     *
     * @param {boolean} value
     * @param {boolean} actionable
     */
    constructor(value: boolean, actionable?: boolean);
    get value(): boolean;
    copy(actionable?: boolean): BasslineBool;
    /**
     *
     * @template {BasslineVisitor} T
     * @param {T} aVisitor
     */
    accept<T extends BasslineVisitor>(aVisitor: T): BasslineBool;
    /** @returns {'bool'}*/
    get kind(): "bool";
    #private;
}
export class BasslineInt extends BasslineValue {
    /**
     *
     * @param {bigint | number} value
     * @param {boolean} actionable
     */
    constructor(value: bigint | number, actionable?: boolean);
    get value(): bigint;
    /**
     *
     * @template {BasslineVisitor} T
     * @param {T} aVisitor
     */
    accept<T extends BasslineVisitor>(aVisitor: T): BasslineInt;
    /** @returns {'int'}*/
    get kind(): "int";
    copy(actionable?: boolean): BasslineInt;
    #private;
}
export class BasslineFloat extends BasslineValue {
    /**
     *
     * @param {number} value
     * @param {boolean} actionable
     */
    constructor(value: number, actionable?: boolean);
    get value(): number;
    /**
     *
     * @template {BasslineVisitor} T
     * @param {T} aVisitor
     */
    accept<T extends BasslineVisitor>(aVisitor: T): BasslineFloat;
    copy(actionable?: boolean): BasslineFloat;
    /** @returns {'float'}*/
    get kind(): "float";
    #private;
}
export class BasslineString extends BasslineValue {
    /**
     *
     * @param {string} value
     * @param {boolean} actionable
     */
    constructor(value: string, actionable?: boolean);
    get value(): string;
    /**
     *
     * @template {BasslineVisitor} T
     * @param {T} aVisitor
     */
    accept<T extends BasslineVisitor>(aVisitor: T): BasslineString;
    copy(actionable?: boolean): BasslineString;
    /** @returns {'string'}*/
    get kind(): "string";
    #private;
}
export class BasslineSymbol extends BasslineValue {
    /**
     *
     * @param {string} value
     * @param {boolean} actionable
     */
    constructor(value: string, actionable?: boolean);
    get value(): string;
    /**
     *
     * @template {BasslineVisitor} T
     * @param {T} aVisitor
     */
    accept<T extends BasslineVisitor>(aVisitor: T): BasslineSymbol;
    copy(actionable?: boolean): BasslineSymbol;
    /** @returns {'symbol'}*/
    get kind(): "symbol";
    #private;
}
export class BasslineBytes extends BasslineValue {
    /**
     *
     * @param {Uint8Array} value
     * @param {boolean} actionable
     */
    constructor(value: Uint8Array, actionable?: boolean);
    get value(): Uint8Array<ArrayBuffer>;
    /**
     *
     * @template {BasslineVisitor} T
     * @param {T} aVisitor
     */
    accept<T extends BasslineVisitor>(aVisitor: T): BasslineBytes;
    /** @returns {'bytes'}*/
    get kind(): "bytes";
    copy(actionable?: boolean): BasslineBytes;
    #private;
}
export class BasslineList extends BasslineValue {
    /**
     *
     * @param {BasslineValue[]} items
     * @param {boolean} actionable
     */
    constructor(items: BasslineValue[], actionable?: boolean);
    /**
     *
     * @param {number} index
     */
    at(index: number): BasslineValue;
    length(): number;
    /**
     *
     * @param  {...BasslineValue} items
     * @returns {BasslineList}
     */
    append(...items: BasslineValue[]): BasslineList;
    /**
     *
     * @param {(item: BasslineValue, index: number, array: BasslineValue[]) => BasslineValue} callback
     * @returns {BasslineList}
     */
    map(callback: (item: BasslineValue, index: number, array: BasslineValue[]) => BasslineValue): BasslineList;
    /**
     *
     * @param {(item: BasslineValue, index: number, array: BasslineValue[]) => boolean} callback
     * @returns {BasslineList}
     */
    filter(callback: (item: BasslineValue, index: number, array: BasslineValue[]) => boolean): BasslineList;
    get value(): BasslineValue[];
    /**
     *
     * @template {BasslineVisitor} T
     * @param {T} aVisitor
     */
    accept<T extends BasslineVisitor>(aVisitor: T): BasslineList;
    copy(actionable?: boolean): BasslineList;
    /** @returns {'list'}*/
    get kind(): "list";
    [Symbol.iterator](): Generator<BasslineValue, void, unknown>;
    #private;
}
export class BasslineDict extends BasslineValue {
    /**
     *
     * @param {Array<[BasslineValue, BasslineValue]>} entries
     * @param {boolean} actionable
     */
    constructor(entries: Array<[BasslineValue, BasslineValue]>, actionable?: boolean);
    /**
     * @returns {Map<BasslineValue, BasslineValue>}
     */
    get value(): Map<BasslineValue, BasslineValue>;
    /**
     *
     * @param {(entry: [BasslineValue, BasslineValue], index: number, array: [BasslineValue, BasslineValue][]) => [BasslineValue, BasslineValue]} callback
     */
    map(callback: (entry: [BasslineValue, BasslineValue], index: number, array: [BasslineValue, BasslineValue][]) => [BasslineValue, BasslineValue]): BasslineDict;
    /**
     *
     * @param {(entry: [BasslineValue, BasslineValue], index: number, array: [BasslineValue, BasslineValue][]) => boolean} callback
     */
    filter(callback: (entry: [BasslineValue, BasslineValue], index: number, array: [BasslineValue, BasslineValue][]) => boolean): BasslineDict;
    /**
     *
     * @param {...[BasslineValue, BasslineValue]} entries
     */
    append(...entries: [BasslineValue, BasslineValue][]): BasslineDict;
    /**
     *
     * @param {...BasslineValue} keys
     */
    delete(...keys: BasslineValue[]): BasslineDict;
    /**
     *
     * @param {BasslineValue} k
     * @param {BasslineValue} v
     * @returns {BasslineDict}
     */
    set(k: BasslineValue, v: BasslineValue): BasslineDict;
    /**
     *
     * @param {BasslineValue} k
     * @returns {BasslineValue}
     */
    get(k: BasslineValue): BasslineValue;
    /**
     *
     * @param {BasslineValue} k
     * @returns {boolean}
     */
    has(k: BasslineValue): boolean;
    /**
     * @template {BasslineVisitor} T
     * @param {T} aVisitor
     */
    accept<T extends BasslineVisitor>(aVisitor: T): BasslineDict;
    /**
     *
     * @param {boolean} actionable
     * @returns {BasslineDict}
     */
    copy(actionable: boolean): BasslineDict;
    /** @returns {'dict'} */
    get kind(): "dict";
    [Symbol.iterator](): Generator<any[], void, unknown>;
    #private;
}
export class BasslineRecord extends BasslineValue {
    /**
     *
     * @param {BasslineValue[]} record
     * @param {boolean} actionable
     */
    constructor(record: BasslineValue[], actionable?: boolean);
    get value(): BasslineValue[];
    get head(): BasslineValue;
    get fields(): BasslineValue[];
    /**
     *
     * @param {(value: BasslineValue, index: number, array: BasslineValue[]) => BasslineValue} callback
     */
    map(callback: (value: BasslineValue, index: number, array: BasslineValue[]) => BasslineValue): BasslineRecord;
    /**
     *
     * @param {(value: BasslineValue, index: number, array: BasslineValue[]) => boolean} callback
     * @returns {BasslineRecord}
     */
    filter(callback: (value: BasslineValue, index: number, array: BasslineValue[]) => boolean): BasslineRecord;
    /**
     * @template {BasslineVisitor} T
     * @param {T} aVisitor
     */
    accept<T extends BasslineVisitor>(aVisitor: T): BasslineRecord;
    /**
     *
     * @param {boolean} actionable
     * @returns {BasslineRecord}
     */
    copy(actionable: boolean): BasslineRecord;
    /** @returns {'record'} */
    get kind(): "record";
    #private;
}
export class BasslineSet extends BasslineValue {
    /**
     *
     * @param {BasslineValue[]} members
     * @param {boolean} actionable
     */
    constructor(members: BasslineValue[], actionable?: boolean);
    /**
     * @returns {BasslineValue[]}
     */
    get value(): BasslineValue[];
    /**
     *
     * @param {(value: BasslineValue, index: number, array: BasslineValue[]) => BasslineValue} callback
     * @returns {BasslineSet}
     */
    map(callback: (value: BasslineValue, index: number, array: BasslineValue[]) => BasslineValue): BasslineSet;
    /**
     *
     * @param {(value: BasslineValue, index: number, array: BasslineValue[]) => boolean} callback
     * @returns {BasslineSet}
     */
    filter(callback: (value: BasslineValue, index: number, array: BasslineValue[]) => boolean): BasslineSet;
    /**
     *
     * @param {...BasslineValue} members
     * @returns {BasslineSet}
     */
    append(...members: BasslineValue[]): BasslineSet;
    /**
     *
     * @param {...BasslineValue} members
     * @returns {BasslineSet}
     */
    delete(...members: BasslineValue[]): BasslineSet;
    /**
     *
     * @param {BasslineValue} m
     * @returns {BasslineSet}
     */
    add(m: BasslineValue): BasslineSet;
    /**
     *
     * @param {...BasslineValue} members
     * @returns {boolean}
     */
    has(...members: BasslineValue[]): boolean;
    /**
     * @template {BasslineVisitor} T
     * @param {T} aVisitor
     */
    accept<T extends BasslineVisitor>(aVisitor: T): BasslineSet;
    copy(actionable?: boolean): BasslineSet;
    /** @returns {'set'} */
    get kind(): "set";
    [Symbol.iterator](): Generator<any, void, unknown>;
    #private;
}
export function nil(): BasslineNil;
/** @type {(b: boolean) => BasslineBool} */
export const bool: (b: boolean) => BasslineBool;
/** @type {(n: number | bigint) => BasslineInt} */
export const int: (n: number | bigint) => BasslineInt;
/** @type {(x: number) => BasslineFloat} */
export const float: (x: number) => BasslineFloat;
/** @type {(s: string) => BasslineString} */
export const str: (s: string) => BasslineString;
/** @type {(s: string) => BasslineSymbol} */
export const sym: (s: string) => BasslineSymbol;
/** @type {(u8: Uint8Array) => BasslineBytes} */
export const bytes: (u8: Uint8Array) => BasslineBytes;
/** @type {(items: BasslineValue[]) => BasslineList} */
export const list: (items: BasslineValue[]) => BasslineList;
/** @type {(entries: [BasslineValue, BasslineValue][]) => BasslineDict} */
export const dict: (entries: [BasslineValue, BasslineValue][]) => BasslineDict;
/** @type {(head: BasslineValue, ...fields: BasslineValue[]) => BasslineRecord} */
export const record: (head: BasslineValue, ...fields: BasslineValue[]) => BasslineRecord;
/** @type {(members: BasslineValue[]) => BasslineSet} */
export const set: (members: BasslineValue[]) => BasslineSet;
export class BasslineVisitor {
    /**
     *
     * @param {BasslineValue} aValue
     */
    visit(aValue: BasslineValue): void;
    /**
     * @param {BasslineNil} aNil
     */
    visitNil(aNil: BasslineNil): BasslineNil;
    /**
     * @param {BasslineBool} aBool
     */
    visitBool(aBool: BasslineBool): BasslineBool;
    /**
     * @param {BasslineInt} anInt
     */
    visitInt(anInt: BasslineInt): BasslineInt;
    /**
     * @param {BasslineFloat} aFloat
     */
    visitFloat(aFloat: BasslineFloat): BasslineFloat;
    /**
     * @param {BasslineString} aString
     */
    visitString(aString: BasslineString): BasslineString;
    /**
     * @param {BasslineSymbol} aSymbol
     */
    visitSymbol(aSymbol: BasslineSymbol): BasslineSymbol;
    /**
     * @param {BasslineBytes} aBytes
     */
    visitBytes(aBytes: BasslineBytes): BasslineBytes;
    /**
     * @param {BasslineList} aList
     */
    visitList(aList: BasslineList): BasslineList;
    /**
     * @param {BasslineDict} aDict
     */
    visitDict(aDict: BasslineDict): BasslineDict;
    /**
     * @param {BasslineRecord} aRecord
     */
    visitRecord(aRecord: BasslineRecord): BasslineRecord;
    /**
     * @param {BasslineSet} aSet
     */
    visitSet(aSet: BasslineSet): BasslineSet;
}
export class ActionableVisitor extends BasslineVisitor {
    foundActionable: boolean;
}
export class CycleFreeVisitor extends BasslineVisitor {
    seen: Set<any>;
    cycleDetected: boolean;
    /**
     * @param {BasslineValue} aValue
     */
    visit(aValue: BasslineValue): void | this;
}
/** @type {(v: BasslineValue) => boolean} */
export const isData: (v: BasslineValue) => boolean;
/** @type {(v: BasslineValue) => boolean} */
export const isActionable: (v: BasslineValue) => boolean;
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
export const ACTIONABLE: 128;
export const TAG_MASK: 127;
export class CEVisitor extends BasslineVisitor {
    /** @type {number[]} */
    sink: number[];
    /**
     * @param {number} b
     */
    byte(b: number): this;
    /**
     * @param {Uint8Array} u8
     */
    raw(u8: Uint8Array): this;
    /**
     * @param {number} n
     */
    varint(n: number): this;
    toUint8Array(): Uint8Array<ArrayBuffer>;
    /**
     * Encodes a frame consisting of a descriptor byte, a varint length, and the body bytes.
     * The body is built in a subvisitor so it's length is known before writing.
     * @param {number} tag prefix tag to encode
     * @param {boolean} actionable whether or not the value is actionable
     * @param {(body: CEVisitor) => void} emit function that receives a sub-visitor to build the frame body
     */
    frame(tag: number, actionable: boolean, emit: (body: CEVisitor) => void): this;
}
export class BasslineDecoder {
    /**
     * @param {Uint8Array} input
     * @returns {BasslineValue}
     */
    static one(input: Uint8Array): BasslineValue;
    /**
     * @param {Uint8Array} input
     * @returns {BasslineValue[]}
     */
    static all(input: Uint8Array): BasslineValue[];
    /**
     * @param {Uint8Array} bytes
     */
    constructor(bytes: Uint8Array);
    /** @type {number} */
    pos: number;
    bytes: Uint8Array<ArrayBufferLike>;
    readByte(): number;
    /**
     * @param {number} n The number of bytes to read
     */
    readBytes(n: number): Uint8Array<ArrayBufferLike>;
    readVarint(): number;
    /**
     * @param {Uint8Array} b
     */
    decodeUtf8(b: Uint8Array): string;
    /**
     * @param {Uint8Array} b
     */
    decodeF64(b: Uint8Array): number;
    /**
     * @param {Uint8Array} b
     */
    decodeInt(b: Uint8Array): bigint;
    frameEnd(): number;
    /**
     * @returns {BasslineValue}
     */
    decodeValue(): BasslineValue;
    /**
     * @param {boolean} actionable
     * @returns {BasslineList}
     */
    decodeList(actionable: boolean): BasslineList;
    /**
     *
     * @param {boolean} actionable
     * @returns {BasslineDict}
     */
    decodeDict(actionable: boolean): BasslineDict;
    /**
     * @param {boolean} actionable
     * @returns {BasslineRecord}
     */
    decodeRecord(actionable: boolean): BasslineRecord;
    /**
     *
     * @param {boolean} actionable
     * @returns {BasslineSet}
     */
    decodeSet(actionable: boolean): BasslineSet;
    /**
     * @param {number} tag
     * @param {boolean} actionable
     */
    decodeByTag(tag: number, actionable: boolean): BasslineNil | BasslineBool | BasslineInt | BasslineFloat | BasslineString | BasslineSymbol | BasslineBytes | BasslineList | BasslineDict | BasslineRecord | BasslineSet;
}
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
export type Values = ScalarValues & FrameValues;
export type Scalar = ScalarValues[keyof ScalarValues];
export type Frame = FrameValues[keyof FrameValues];
export type Value = BasslineValue;
export type ValueKind = keyof Values;
//# sourceMappingURL=data.d.ts.map