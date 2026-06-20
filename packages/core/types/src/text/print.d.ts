/**
 * Pretty-print a value to text. parse(print(v))[0] is eq to v.
 * @param v
 * @param {number} [width] line width that triggers breaking (default 72)
 */
export function print(v: any, width?: number): string;
export class BasslinePP extends BasslineVisitor {
    constructor(width?: number);
    str: string;
    depth: number;
    padding: number;
    width: number;
    write(s: any): void;
    /** Columns written on the current (last) line. */
    column(): number;
    /** A newline followed by the current indentation. */
    break(): void;
    /**
     * Write `node` flat if it fits the line; otherwise run `emitBroken`.
     * @param node
     * @param emitBroken
     */
    compound(node: any, emitBroken: any): void;
    /**
     * A frame broken across lines: open, one indented item per line, close.
     * @param node
     * @param open
     * @param close
     * @param items
     * @param renderItem
     */
    block(node: any, open: any, close: any, items: any, renderItem?: (x: any) => void): void;
    visitNil(v: any): void;
    visitBool(v: any): void;
    visitInt(v: any): void;
    visitFloat(v: any): void;
    visitString(v: any): void;
    visitSymbol(v: any): void;
    visitBytes(v: any): void;
    visitList(aList: any): void;
    visitSet(aSet: any): void;
    visitDict(aDict: any): void;
    visitRecord(aRecord: any): void;
}
import { BasslineVisitor } from '../data.js';
//# sourceMappingURL=print.d.ts.map