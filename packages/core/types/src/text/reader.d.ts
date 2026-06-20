/**
 * Read source text into a document (zero or more values).
 * @param {string} source
 * @returns {Value[]}
 */
export function read(source: string): Value[];
export class ReaderError extends Error {
    /**
     * @param {string} source
     * @param {number} pos
     * @param {string} msg
     */
    constructor(source: string, pos: number, msg: string);
}
import type { Value } from "../data.js";
//# sourceMappingURL=reader.d.ts.map