/**
 * Write one value or an array of values to a binary file.
 * @param path
 * @param values
 */
export function saveBinary(path: any, values: any): void;
/**
 * Decode the sequence of values stored in a binary file.
 * @param path
 */
export function loadBinary(path: any): import("./data.js").BasslineValue[];
/**
 * Write one value or an array of values to a text file.
 * @param path
 * @param values
 */
export function saveText(path: any, values: any): void;
/**
 * Parse a text file into its list of values.
 * @param path
 */
export function loadText(path: any): import("./data.js").BasslineValue[];
/**
 * Convert a text file to binary.
 * @param srcPath
 * @param dstPath
 */
export function textToBinary(srcPath: any, dstPath: any): void;
/**
 * Convert a binary file to text.
 * @param srcPath
 * @param dstPath
 */
export function binaryToText(srcPath: any, dstPath: any): void;
//# sourceMappingURL=files.d.ts.map