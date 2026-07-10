/** @param {boolean} actionable */
export function nil(actionable?: boolean): import("./forms.js").BNil;
/**
 * @param {bigint | number} value
 * @param {boolean} actionable
 */
export function int(value: bigint | number, actionable?: boolean): import("./forms.js").BInt;
/**
 * @param {string} value
 * @param {boolean} actionable
 */
export function string(value: string, actionable?: boolean): import("./forms.js").BString;
/**
 * @param {string} value
 * @param {boolean} actionable
 */
export function symbol(value: string, actionable?: boolean): import("./forms.js").BSymbol;
/**
 * The input is copied, so later writes to it can't reach the value. The
 * payload inside the value is owned by the value: a typed array can't be
 * frozen, so mutating it is undefined behavior (identity is cached from
 * whatever the bytes were when first encoded).
 * @param {Uint8Array} value
 * @param {boolean} actionable
 */
export function bytes(value: Uint8Array, actionable?: boolean): import("./forms.js").BBytes;
/**
 * @param {Value[]} items
 * @param {boolean} actionable
 */
export function list(items: Value[], actionable?: boolean): import("./forms.js").BList;
/**
 * @param {Value[]} aRecord
 * @param {boolean} actionable
 */
export function record(aRecord: Value[], actionable?: boolean): import("./forms.js").BRecord;
/**
 * @param {Value[]} members
 * @param {boolean} actionable
 */
export function set(members: Value[], actionable?: boolean): import("./forms.js").BSet;
/**
 * @param {Array<[Value, Value]>} entries
 * @param {boolean} actionable
 */
export function dict(entries: Array<[Value, Value]>, actionable?: boolean): import("./forms.js").BDict;
/**
 * Values are frozen, so each node's encoding is computed once and cached;
 * the returned array is always a private copy.
 * @param {Value} v
 * @returns {Uint8Array}
 */
export function encode(v: Value): Uint8Array;
/**
 * Total order over values by their CE bytes. This is doesn't keep numeric order
 * @param {Value} a
 * @param {Value} b
 * @returns {number} A negative number if a < b, 0 if a == b, a positive number if a > b
 */
export function cmp(a: Value, b: Value): number;
/**
 * Dedups and sorts an array of values by CE
 * @param {Value[]} values
 * @returns {readonly Value[]}
 */
export function dedup(values: Value[]): readonly Value[];
/**
 * Sorts an array of entries by the key CE
 * This treats keys as LWW
 * @param {Array<[Value, Value]>} entries
 * @returns {ReadonlyArray<[Value, Value]>}
 */
export function dedupEntries(entries: Array<[Value, Value]>): ReadonlyArray<[Value, Value]>;
/**
 *
 * @param {Value} a
 * @param {Value} b
 * @returns {boolean} True if a and b are equal, false otherwise
 */
export function eq(a: Value, b: Value): boolean;
/**
 * Decode exactly one value; trailing bytes are an error.
 * @param {Uint8Array} bytes
 * @param {{maxDepth?: number, maxLength?: number}} [opts]
 */
export function decode(bytes: Uint8Array, opts?: {
    maxDepth?: number;
    maxLength?: number;
}): Value;
/**
 * Decode the sequence of values in the input (a document).
 * @param {Uint8Array} bytes
 * @param {{maxDepth?: number, maxLength?: number}} [opts]
 */
export function decodeAll(bytes: Uint8Array, opts?: {
    maxDepth?: number;
    maxLength?: number;
}): (import("./forms.js").BString | import("./forms.js").BSymbol | import("./forms.js").BSet | import("./forms.js").BDict | import("./forms.js").BRecord | import("./forms.js").BBytes | import("./forms.js").BNil | import("./forms.js").BInt | import("./forms.js").BList)[];
/** Kind name → wire tag. The single authority for the tag numbering. */
export const TAGS: Readonly<{
    nil: 1;
    int: 2;
    string: 3;
    symbol: 4;
    bytes: 5;
    list: 6;
    record: 7;
    dict: 8;
    set: 9;
}>;
export const END_BYTE: 160;
export function headerTag(b: number): number;
export function headerMark(b: number): boolean;
export function headerLen(b: number): number;
export const ENC: TextEncoder;
export const DEC: TextDecoder;
export const CANONICAL_INT: RegExp;
export class BasslineDecoder {
    /**
     * @param {Uint8Array} bytes
     * @param {{maxDepth?: number, maxLength?: number}} [opts]
     */
    constructor(bytes: Uint8Array, { maxDepth, maxLength }?: {
        maxDepth?: number;
        maxLength?: number;
    });
    bytes: Uint8Array<ArrayBufferLike>;
    pos: number;
    maxDepth: number;
    maxLength: number;
    readByte(): number;
    /** @param {number} n The number of bytes to read  */
    readBytes(n: number): Uint8Array<ArrayBufferLike>;
    /**
     * The payload length of a scalar. Each form is mandatory in its range, so
     * every length has exactly one spelling.
     * @param {number} len3 the header's low three bits
     */
    readLength(len3: number): number;
    /**
     * @param {Uint8Array} payload
     * @param {boolean} mark
     */
    decodeInt(payload: Uint8Array, mark: boolean): import("./forms.js").BInt;
    /**
     * @param {number} depth
     * @returns {Value}
     */
    decodeValue(depth?: number): Value;
    /**
     * Children until END, then per-kind validation. Dict keys and set members
     * are checked for strict CE order by comparing their raw byte spans, so
     * construction here trusts the validation and skips re-canonicalizing.
     * @param {number} tag
     * @param {boolean} mark
     * @param {number} depth
     * @returns {Value}
     */
    decodeFrame(tag: number, mark: boolean, depth: number): Value;
    /**
     * @param {Array<[number, number]>} spans
     * @param {string} what
     */
    assertAscending(spans: Array<[number, number]>, what: string): void;
}
import type { Value } from './forms.js';
//# sourceMappingURL=codec.d.ts.map