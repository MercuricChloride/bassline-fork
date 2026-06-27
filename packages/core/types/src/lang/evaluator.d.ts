export function echo(args: any): any;
export function set([aDict]: [any], rt: any): any;
export function fn([name, params, body]: [any, any, any], rt: any): any;
export function apply([target, args]: [any, any], rt: any): any;
export function sheet(cellNodes: any, rt: any): any;
export function makeEvaluator(): BasslineEvaluator;
export function error(tag: any, ...fields: any[]): any;
export class BasslineEvaluator {
    env: Env;
    commands: Map<any, any>;
    transcript: any[];
    visit(node: any): any;
    force(node: any): any;
    lookup(aSymbol: any): any;
    callable(aName: any): boolean;
    exec(aCmd: any, args: any): any;
    inEnv(env: any, thunk: any): any;
    load(source: any): any;
    getTranscript(): string;
    toBassline(): any;
}
export function numeric(fn: any, identity: any): (args: any) => any;
export function add(args: any): any;
export function sub(args: any): any;
export function mul(args: any): any;
export function div(args: any): any;
declare class Env {
    constructor(bindings?: Map<any, any>, parent?: any);
    parent: any;
    bindings: Map<any, any>;
    binding(aName: any): any;
    lookup(aName: any): any;
    define(aName: any, aBinding: any): this;
    setVal(aName: any, aValue: any): this;
    toBassline(): any;
}
export {};
//# sourceMappingURL=evaluator.d.ts.map