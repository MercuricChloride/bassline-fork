/**
 * Write one value or an array of values to a binary file.
 * @param {string} path
 * @param {Value|Value[]} values
 */
export function saveBinary(path: string, values: Value | Value[]): void;
/**
 * Decode the sequence of values stored in a binary file.
 * @param {string} path
 */
export function loadBinary(path: string): (import("./forms.js").BString | import("./forms.js").BSymbol | import("./forms.js").BSet | import("./forms.js").BDict | import("./forms.js").BRecord | import("./forms.js").BBytes | import("./forms.js").BNil | import("./forms.js").BInt | import("./forms.js").BList)[];
/**
 * Write one value or an array of values to a text file.
 * @param {string} path
 * @param {Value|Value[]} values
 */
export function saveText(path: string, values: Value | Value[]): void;
/**
 * Parse a text file into its list of values.
 * @param {string} path
 */
export function loadText(path: string): Value[];
/**
 * Write values to either on-disk form: text when the path ends in .blt
 * or {text} says so, binary otherwise.
 * @param {string} path
 * @param {Value|Value[]} values
 * @param {{text?: boolean}} [opts]
 */
export function saveValues(path: string, values: Value | Value[], opts?: {
    text?: boolean;
}): void;
/**
 * Parse bytes that are either binary CE or utf-8 text. The extension
 * decides when known; otherwise binary is tried first (its decoder is
 * strict), then text.
 * @param {Uint8Array} buf
 * @param {{path?: string, text?: boolean, binary?: boolean}} [opts]
 * @returns {Value[]}
 */
export function parseValues(buf: Uint8Array, opts?: {
    path?: string;
    text?: boolean;
    binary?: boolean;
}): Value[];
/**
 * Load a file in either form, detected by extension or content.
 * @param {string} path
 * @param {{text?: boolean, binary?: boolean}} [opts]
 * @returns {Value[]}
 */
export function loadValues(path: string, opts?: {
    text?: boolean;
    binary?: boolean;
}): Value[];
/**
 * Convert a text file to binary.
 * @param {string} srcPath
 * @param {string} dstPath
 */
export function textToBinary(srcPath: string, dstPath: string): void;
/**
 * Convert a binary file to text.
 * @param {string} srcPath
 * @param {string} dstPath
 */
export function binaryToText(srcPath: string, dstPath: string): void;
export const BINARY_EXT: ".blb";
export const TEXT_EXT: ".blt";
import type { Value } from "./data.js";
//# sourceMappingURL=files.d.ts.map