/**
 * @param {unknown} x
 * @returns {x is Value}
 */
export function isValue(x: unknown): x is Value;
/**
 * @param {Value} x
 * @returns {x is Values[AtomKind]}
 */
export function isAtom(x: Value): x is Values[AtomKind];
/**
 * @param {Value} x
 * @returns {x is Values[FrameKind]}
 */
export function isFrame(x: Value): x is Values[FrameKind];
/**
 * @param {unknown} x
 * @param {string} [msg] - The error message to throw if x is not a Bassline value
 * @throws {TypeError} if x is not a Bassline value.
 * @returns {asserts x is Value}
 */
export function assertValue(x: unknown, msg?: string): asserts x is Value;
export type ValueType<K extends FrameKind | AtomKind, T> = {
    readonly kind: K;
    readonly value: T;
    readonly actionable: boolean;
};
export type BList = {
    readonly kind: "list";
    readonly actionable: boolean;
    readonly value: Value[];
};
export type BRecord = {
    readonly kind: "record";
    readonly actionable: boolean;
    readonly value: [Value, ...Value[]];
};
export type BDict = {
    readonly kind: "dict";
    readonly actionable: boolean;
    readonly value: Array<[Value, Value]>;
};
export type BSet = {
    readonly kind: "set";
    readonly actionable: boolean;
    readonly value: Value[];
};
export type BNil = ValueType<"nil", null>;
export type BInt = ValueType<"int", bigint>;
export type BString = ValueType<"string", string>;
export type BSymbol = ValueType<"symbol", string>;
export type BBytes = ValueType<"bytes", Uint8Array>;
export type Values = {
    nil: BNil;
    int: BInt;
    string: BString;
    symbol: BSymbol;
    bytes: BBytes;
    list: BList;
    record: BRecord;
    dict: BDict;
    set: BSet;
};
export type Value = Values[keyof Values];
export type AtomKind = "bytes" | "int" | "nil" | "string" | "symbol";
export type FrameKind = "list" | "record" | "dict" | "set";
export type ValueKind = keyof Values;
export type Frame = Values[FrameKind];
export type Atom = Values[AtomKind];
//# sourceMappingURL=forms.d.ts.map