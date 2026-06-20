export function cond(cases: any, fallback?: typeof condDefault): (...args: any[]) => any;
export const MSG: unique symbol;
export const WORD: unique symbol;
export const BASSLINE: unique symbol;
export namespace is {
    export function _null(v: any): boolean;
    export { _null as null };
    export function undefined(v: any): boolean;
    export function nan(v: any): boolean;
    export function number(v: any): boolean;
    export function string(v: any): v is string;
    export function boolean(v: any): v is boolean;
    export function array(v: any): v is any[];
    export function object(v: any): boolean;
    export function fn(v: any): boolean;
    export function bassline(v: any): any;
    export function word(v: any): any;
    export function msg(v: any): boolean;
    export function nbound(v: any): any;
    export function vbound(v: any): boolean;
    export function bound(v: any): any;
    export function nil(v: any): boolean;
    export function scalar(v: any): boolean;
    export function noun(v: any): any;
    export function verb(v: any): boolean;
}
export function caseLambda(...fns: any[]): (...args: any[]) => any;
export class Word {
    get [WORD](): boolean;
}
export class Msg {
    get [MSG](): boolean;
    [Symbol.iterator](): Generator<any[], void, unknown>;
}
export class OtherBassline {
    words: Map<any, any>;
    word(n: any, v: any): (...args: any[]) => any;
    msg(aFn: any): any;
}
export class Bassline {
    static extend(...mixins: any[]): any;
    is: {
        null: (v: any) => boolean;
        undefined: (v: any) => boolean;
        nan: (v: any) => boolean;
        number: (v: any) => boolean;
        string: (v: any) => v is string;
        boolean: (v: any) => v is boolean;
        array: (v: any) => v is any[];
        object: (v: any) => boolean;
        fn: (v: any) => boolean;
        bassline: (v: any) => any;
        word: (v: any) => any;
        msg: (v: any) => boolean;
        nbound: (v: any) => any;
        vbound: (v: any) => boolean;
        bound: (v: any) => any;
        nil: (v: any) => boolean;
        scalar: (v: any) => boolean;
        noun: (v: any) => any;
        verb: (v: any) => boolean;
    };
    word(n: any, v: any): any;
    verb(fn: any): any;
    msg(dict?: {}): any;
    get reference(): this;
    derive(fn: any): any;
    extend(...fns: any[]): any;
    get [BASSLINE](): boolean;
}
export default Bassline;
declare function condDefault(args: any): void;
//# sourceMappingURL=bassline.d.ts.map