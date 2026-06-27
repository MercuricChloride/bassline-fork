//@ts-check
// The borth evaluator: a concatenative stack machine over bassline values.
// Quotations are lists; a symbol runs the word it names; anything else is data
// and is pushed. The standard word set lives in words.js (installed by init()).
/** @import {Value, Values} from "@bassline/core/data" */
import { fresh } from '@bassline/core/data'
import { installStdlib } from './words.js'
import {
  isBorthDocument,
  findDefs,
  findStack,
  findBorthExpressions,
} from './document.js'

/**
 * A recoverable evaluation failure. It is thrown for clean unwinding and turned
 * into inert `(error …)` data at the block boundary (see {@link errorValue}), so
 * failures surface on the stack rather than crashing the host.
 */
export class BorthError extends Error {
  /**
   * @param {string} tag
   * @param {...Value} fields
   */
  constructor(tag, ...fields) {
    super(`borth error: ${tag}`)
    this.tag = tag
    /** @type {Value[]} */
    this.fields = fields
    /** @type {Values['symbol'] | undefined} the word whose execution raised it */
    this.word = undefined
  }
}

/**
 * Build an `(error tag …fields)` data value (unmarked, so it rides the stack as
 * data — the convention from core's lang evaluator).
 * @param {string} tag
 * @param {...Value} fields
 */
export const borthError = (tag, ...fields) =>
  fresh.record([fresh.symbol('error'), fresh.symbol(tag), ...fields])

/** @param {BorthError} e */
const errorValue = e =>
  borthError(e.tag, ...(e.word ? [e.word] : []), ...e.fields)

/** @param {Value} v @returns {boolean} */
export const truthy = v => (v.kind === 'bool' ? v.value : v.kind !== 'nil')

/** @param {Value} v @returns {Values['int'] | Values['float']} */
export function asNum(v) {
  if (v.kind === 'int' || v.kind === 'float') return v
  throw new BorthError('not-a-number', v)
}

/** @param {Values['int'] | Values['float']} v @returns {number} */
export const toFloat = v => (v.kind === 'int' ? Number(v.value) : v.value)

export class BorthEvaluator {
  /** @type {Value[]} */
  stack = []
  /** @type {Map<string, {exec: (evaluator: BorthEvaluator, quote: Values['list']) => void, quote: Values['list']}>} */
  bindings = new Map()

  /** Install the standard word set. */
  init() {
    installStdlib(this)
    return this
  }

  /**
   * Evaluate one value: a symbol runs the word it names; anything else is data
   * and is pushed (lists are pushed as quotes, not run).
   * @param {Value} v
   */
  evaluate(v) {
    if (v.kind === 'symbol') {
      const resolved = this.lookup(v)
      if (!resolved) throw new BorthError('unbound', v)
      try {
        resolved.exec(this, resolved.quote)
      } catch (e) {
        // Attribute the failure to the innermost word that raised it.
        if (e instanceof BorthError && e.word === undefined) e.word = v
        throw e
      }
    } else {
      this.push(v)
    }
  }

  /**
   * Run each value of a quote in order.
   * @param {Values['list']} quote
   */
  docol(quote) {
    for (const val of quote) this.evaluate(val)
  }

  /** @param {Value} v */
  push(v) {
    this.stack.push(v)
  }

  /** @returns {Value} */
  pop() {
    if (this.stack.length === 0) throw new BorthError('underflow')
    return /** @type {Value} */ (this.stack.pop())
  }

  /** Pop a value that must be a quote (list). @returns {Values['list']} */
  popQuote() {
    const q = this.pop()
    if (q.kind !== 'list') throw new BorthError('not-a-quote', q)
    return q
  }

  /**
   * Binary arithmetic. Both ints → `intFn` over bigints; otherwise `floatFn`
   * over JS numbers.
   * @param {(a: bigint, b: bigint) => bigint} intFn
   * @param {(a: number, b: number) => number} floatFn
   */
  binop(intFn, floatFn) {
    const b = asNum(this.pop())
    const a = asNum(this.pop())
    if (a.kind === 'int' && b.kind === 'int') {
      this.push(fresh.int(intFn(a.value, b.value)))
    } else {
      this.push(fresh.float(floatFn(toFloat(a), toFloat(b))))
    }
  }

  /**
   * Numeric ordering: pops two numbers, pushes `keep(sign(a - b))` as a bool.
   * @param {(r: number) => boolean} keep
   */
  ord(keep) {
    const b = asNum(this.pop())
    const a = asNum(this.pop())
    let r
    if (a.kind === 'int' && b.kind === 'int') {
      r = a.value < b.value ? -1 : a.value > b.value ? 1 : 0
    } else {
      const x = toFloat(a)
      const y = toFloat(b)
      r = x < y ? -1 : x > y ? 1 : 0
    }
    this.push(fresh.bool(keep(r)))
  }

  /**
   * @param {Values['symbol']} symbol
   */
  lookup(symbol) {
    return this.bindings.get(symbol.copy(false).ceKey())
  }

  /**
   * Bind a symbol to a quote. The body is run on each invocation, so quotes may
   * reference words defined later in the same document.
   * @param {Values['symbol']} symbol
   * @param {Values['list']} quote
   */
  def(symbol, quote) {
    this.bindings.set(symbol.copy(false).ceKey(), {
      quote,
      exec: (e, q) => e.docol(q),
    })
    return symbol
  }

  /**
   * Bind a native word. Keyed mark-insensitively, like {@link def}, so a bare
   * symbol resolves it.
   * @param {string} name
   * @param {(evaluator: BorthEvaluator) => void} exec
   */
  prim(name, exec) {
    const symbol = fresh.symbol(name)
    this.bindings.set(symbol.ceKey(), { quote: fresh.list([]), exec })
    return symbol
  }

  /**
   * Bind every entry of a `(def {name: [quote] …})` block.
   * @param {Values['record']} directive
   */
  loadDef(directive) {
    const [dict] = directive.fields
    if (dict?.kind !== 'dict')
      throw new TypeError('def expects a dict of name -> quote')
    for (const [name, quote] of dict.value.values()) {
      if (name.kind !== 'symbol')
        throw new TypeError('def names must be symbols')
      if (quote.kind !== 'list')
        throw new TypeError('def bodies must be quotes (lists)')
      this.def(name, quote)
    }
  }

  /**
   * Run one `(borth …)` block's expressions. On a {@link BorthError} the error
   * value is pushed and evaluation halts (returns false); other exceptions
   * propagate.
   * @param {Values['record']} block
   * @returns {boolean} whether the block completed without error
   */
  runBlock(block) {
    try {
      for (const expr of block.fields) this.evaluate(expr)
      return true
    } catch (e) {
      if (e instanceof BorthError) {
        this.push(errorValue(e))
        return false
      }
      throw e
    }
  }

  /** Bind every `(def {…})` and seed the stack from the first `(stack …)`. */
  /** @param {Value[]} doc */
  prepare(doc) {
    if (!isBorthDocument(doc)) throw new TypeError('Not a borth document')
    for (const def of findDefs(doc)) this.loadDef(def)
    const stack = findStack(doc)
    if (stack) for (const item of stack.fields) this.push(item)
  }

  /**
   * Run a whole borth document: prepare, then evaluate each `(borth …)` block in
   * order, halting at the first error. The final {@link stack} is the result.
   * @param {Value[]} doc
   */
  evaluateDocument(doc) {
    this.prepare(doc)
    for (const block of findBorthExpressions(doc)) {
      if (!this.runBlock(block)) break
    }
  }

  /**
   * Run a single `(borth …)` block against the document's prepared state (all
   * defs bound, stack seeded). Used by the editor's per-block "Evaluate".
   * @param {Value[]} doc
   * @param {Values['record']} block
   */
  evaluateBlock(doc, block) {
    this.prepare(doc)
    this.runBlock(block)
  }
}
