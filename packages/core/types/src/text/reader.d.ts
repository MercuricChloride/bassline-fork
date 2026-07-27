/**
 * A parsed value together with its source span and child spans, in UTF-16
 * code-unit offsets. The mark is part of the span: `start` sits before a
 * frame's leading `!`, and `end` sits just past an atom's trailing `!`.
 * `children` are the sub-spans in document order (record head + fields, dict
 * keys + values, list and set members); atoms have none.
 * @typedef {object} Spanned
 * @property {Value} value
 * @property {number} start
 * @property {number} end
 * @property {Spanned[]} children
 */
/**
 * Read source text into a document (zero or more values).
 * @param {string} source
 * @param {{maxDepth?: number}} [opts]
 * @returns {Value[]}
 */
export function read(source: string, opts?: {
    maxDepth?: number;
}): Value[];
/**
 * Like {@link read}, but each value is wrapped with its source span. `read` is
 * the projection `readSpans(source).map(s => s.value)`, so the values produced
 * are identical; only the span metadata is extra.
 *
 * The reader recurses per frame, so a `maxDepth` far past the default trades
 * the positioned depth error for the engine's own stack-overflow ceiling
 * (around 1700 frames).
 * @param {string} source
 * @param {{maxDepth?: number}} [opts]
 * @returns {Spanned[]}
 */
export function readSpans(source: string, opts?: {
    maxDepth?: number;
}): Spanned[];
export class ReaderError extends Error {
    /**
     * @param {string} source
     * @param {number} pos
     * @param {string} msg
     */
    constructor(source: string, pos: number, msg: string);
    /** UTF-16 code-unit offset into the source where the error was detected. */
    pos: number;
    line: number;
    col: number;
}
/**
 * A parsed value together with its source span and child spans, in UTF-16
 * code-unit offsets. The mark is part of the span: `start` sits before a
 * frame's leading `!`, and `end` sits just past an atom's trailing `!`.
 * `children` are the sub-spans in document order (record head + fields, dict
 * keys + values, list and set members); atoms have none.
 */
export type Spanned = {
    value: Value;
    start: number;
    end: number;
    children: Spanned[];
};
import type { Value } from "../data.js";
//# sourceMappingURL=reader.d.ts.map