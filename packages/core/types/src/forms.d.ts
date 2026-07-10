/**
 * Note! This is not a thorough or complete implementation rn.
 * Too bad! I'll fix this up later fr.
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
export type BNil = {
    readonly kind: "nil";
    readonly value: null;
    readonly actionable: boolean;
};
export type BInt = {
    readonly kind: "int";
    readonly value: bigint;
    readonly actionable: boolean;
};
export type BString = {
    readonly kind: "string";
    readonly value: string;
    readonly actionable: boolean;
};
export type BSymbol = {
    readonly kind: "symbol";
    readonly value: string;
    readonly actionable: boolean;
};
export type BBytes = {
    readonly kind: "bytes";
    readonly value: Uint8Array;
    readonly actionable: boolean;
};
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