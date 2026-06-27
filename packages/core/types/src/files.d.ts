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
export function loadBinary(path: string): Value[];
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
import type { Value } from "./data.js";
//# sourceMappingURL=files.d.ts.map