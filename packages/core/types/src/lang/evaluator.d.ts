export function echo(args: any): import("../data.js").BasslineNil;
export function set([aDict]: [any], rt: any): import("../data.js").BasslineNil;
export function fn([name, params, body]: [any, any, any], rt: any): import("../data.js").BasslineNil;
export function apply([target, args]: [any, any], rt: any): any;
export function sheet(cellNodes: any, rt: any): any;
export function makeEvaluator(): BasslineEvaluator;
export function error(tag: any, ...fields: any[]): import("../data.js").BasslineRecord;
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
    load(source: any): import("../data.js").BasslineNil;
    getTranscript(): string;
    toBassline(): import("../data.js").BasslineRecord;
}
export function numeric(fn: any, identity: any): (args: any) => import("../data.js").BasslineInt | import("../data.js").BasslineFloat;
export function add(args: any): import("../data.js").BasslineInt | import("../data.js").BasslineFloat;
export function sub(args: any): import("../data.js").BasslineInt | import("../data.js").BasslineFloat;
export function mul(args: any): import("../data.js").BasslineInt | import("../data.js").BasslineFloat;
export function div(args: any): import("../data.js").BasslineInt | import("../data.js").BasslineFloat;
declare class Env {
    constructor(bindings?: Map<any, any>, parent?: any);
    parent: any;
    bindings: Map<any, any>;
    binding(aName: any): any;
    lookup(aName: any): any;
    define(aName: any, aBinding: any): this;
    setVal(aName: any, aValue: any): this;
    toBassline(): import("../data.js").BasslineRecord;
}
export {};
//# sourceMappingURL=evaluator.d.ts.map