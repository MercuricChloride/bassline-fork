// A small applicative evaluator over Bassline values.
//
// Two grammatical forms, told apart by the mark (`):
//   - data is inert: an unmarked value evaluates to itself
//   - a marked record `<head ..fields>` is a call: run `head` over its fields
//   - a marked symbol `name` is a dereference: look `name` up in the env
//
// Arguments are evaluated *explicitly, through quotation*. A call's fields are
// passed as written, each evaluated only if it is itself marked. So `<f a `b>`
// hands `f` the literal symbol `a` and the looked-up value of `b`. When you'd
// rather evaluate every argument without marking each one, `<apply f [..]>`
// forces the whole list (see `apply` below).
//
// Two walks make that work:
//   - `visit` is gated: evaluate a node iff it is marked. It drives the top
//     level and argument evaluation.
//   - `force` is active: evaluate this node regardless of its mark (symbols
//     deref, callable records apply). It is how `apply` and function bodies run
//     an otherwise-inert expression.

import { nil, dict, record, sym, int, float, assertValue } from '../data.js'
import { read, print } from '../text/index.js'

class MissingCommandError extends Error {
  constructor(command) {
    super(`Missing command: ${command}`)
  }
}

// An error value: inert data naming a failure, e.g. <error unbound x>.
export const error = (tag, ...fields) =>
  record(sym('error'), sym(tag), ...fields)

class Env {
  constructor(bindings = new Map(), parent = null) {
    this.parent = parent
    this.bindings = new Map(bindings)
  }

  // The raw binding for a name by walking the scope chain
  binding(aName) {
    if (aName && aName.kind === 'symbol') aName = aName.value
    if (this.bindings.has(aName)) return this.bindings.get(aName)
    return this.parent ? this.parent.binding(aName) : undefined
  }

  // Dereference a name to a value: a function to its source record, a thunk by
  // forcing it (lazily, once), anything else as-is.
  lookup(aName) {
    const b = this.binding(aName)
    if (b instanceof Closure) return b.source
    if (b instanceof Thunk) return b.force()
    return b
  }

  define(aName, aBinding) {
    if (typeof aName !== 'string') throw new Error('Name must be a string')
    this.bindings.set(aName, aBinding)
    return this
  }

  setVal(aName, aValue) {
    if (typeof aName !== 'string') throw new Error('Name must be a string')
    assertValue(aValue)
    this.bindings.set(aName, aValue)
    return this
  }

  toBassline() {
    const entries = []
    for (const [k, b] of this.bindings) {
      const value =
        b instanceof Closure ? b.source : b instanceof Thunk ? b.formula : b
      entries.push([sym(k), value])
    }
    return record(sym('environment'), dict(entries))
  }
}

class Closure {
  constructor(params, body, env, source) {
    this.params = params
    this.body = body
    this.env = env
    this.source = source
  }

  call(args, rt) {
    if (args.length !== this.params.length) {
      throw new Error(`expected ${this.params.length} args, got ${args.length}`)
    }
    const local = new Env(new Map(), this.env)
    this.params.forEach((p, i) => local.setVal(p, args[i]))
    return rt.inEnv(local, () => rt.force(this.body))
  }
}

// A lazy cell: a formula evaluated on first lookup, memoized, with a forcing
// flag so a reference cycle resolves to <error cycle NAME> instead of looping.
class Thunk {
  constructor(name, formula, rt) {
    this.name = name
    this.formula = formula
    this.rt = rt
    this.state = 'new' // 'new' | 'forcing' | 'done'
    this.value = undefined
  }

  force() {
    if (this.state === 'done') return this.value
    if (this.state === 'forcing') return error('cycle', sym(this.name))
    this.state = 'forcing'
    this.value = this.rt.visit(this.formula) // gated: marks decide, not eager
    this.state = 'done'
    return this.value
  }
}

export class BasslineEvaluator {
  env = new Env()
  commands = new Map()
  transcript = []

  // gated walk semantics:
  // only evaluate a node when it is an actionable (symbol | record with a symbol head)
  visit(node) {
    if (node.kind === 'symbol')
      return node.actionable ? this.lookup(node) : node
    if (node.kind === 'record') {
      if (node.actionable && node.head.kind === 'symbol') {
        return this.exec(
          node.head.value,
          node.fields.map(f => this.visit(f))
        )
      }
      return node
    }
    return node
  }

  // active walk semantics:
  // evaluate this node regardless of whether its actionable.
  // Symbols deref and callable records apply; data and quotations are returned untouched.
  force(node) {
    if (node.kind === 'symbol') return this.lookup(node)
    if (
      node.kind === 'record' &&
      node.head.kind === 'symbol' &&
      this.callable(node.head.value)
    ) {
      return this.exec(
        node.head.value,
        node.fields.map(f => this.visit(f))
      )
    }
    return node
  }

  lookup(aSymbol) {
    const value = this.env.lookup(aSymbol)
    return value === undefined ? error('unbound', sym(aSymbol.value)) : value
  }

  callable(aName) {
    return (
      this.commands.has(aName) || this.env.binding(aName) instanceof Closure
    )
  }

  exec(aCmd, args) {
    const cmd = this.commands.get(aCmd)
    if (cmd) return cmd(args, this)
    const target = this.env.binding(aCmd)
    if (target instanceof Closure) return target.call(args, this)
    throw new MissingCommandError(aCmd)
  }

  // Run `thunk` with `env` as the active environment, then restore.
  inEnv(env, thunk) {
    const prev = this.env
    this.env = env
    try {
      return thunk()
    } finally {
      this.env = prev
    }
  }

  load(source) {
    let res = nil()
    this.transcript.push(source)
    for (const node of read(source)) res = this.visit(node)
    return res
  }

  getTranscript() {
    return '\n' + this.transcript.join('\n')
  }

  toBassline() {
    return this.env.toBassline()
  }
}

// ================ commands ================

export function echo(args) {
  for (const arg of args) console.log(print(arg))
  return nil()
}

export function set([aDict], rt) {
  let res = nil()
  for (const [k, v] of aDict) {
    if (k.kind !== 'symbol') throw new Error('set key must be a symbol')
    rt.env.setVal(k.value, v)
    res = v
  }
  return res
}

export const numeric = (fn, identity) => args => {
  const allInt = args.every(a => a.kind === 'int')
  const nums = args.map(a => (allInt ? a.value : Number(a.value)))
  const id = allInt ? BigInt(identity) : identity
  const acc = nums.length > 1 ? nums.reduce(fn) : nums.reduce(fn, id)
  return allInt ? int(acc) : float(acc)
}

export const add = numeric((a, b) => a + b, 0)
export const sub = numeric((a, b) => a - b, 0)
export const mul = numeric((a, b) => a * b, 1)
export const div = numeric((a, b) => a / b, 1)

// `<fn name [p ..] body>` binds `name` to a closure. The body is captured inert
// (it is an unmarked expression) and forced, in a fresh child env on each call.
export function fn([name, params, body], rt) {
  const paramNames = params.value.map(p => p.value)
  const source = record(sym('fn'), name, params, body)
  rt.env.define(name.value, new Closure(paramNames, body, rt.env, source))
  return nil()
}

// `<apply f [a b ..]>` evaluates every element of the list (no marks needed)
// and calls `f` with the results — ordinary applicative evaluation.
export function apply([target, args], rt) {
  if (target.kind !== 'symbol') throw new Error('apply expects a symbol target')
  return rt.exec(
    target.value,
    args.value.map(node => rt.force(node))
  )
}

// `<sheet <cell NAME FORMULA> ..>` evaluates to a new sheet whose cells gain a
// computed value: <cell NAME FORMULA VALUE>. Cells bind lazily in a sheet-local
// env, so a formula reaches its neighbours by name (a marked symbol is a cell
// reference) and dependency order falls out of forcing. The formula stays in
// the cell — it is a value — so the result re-saves as-is.
export function sheet(cellNodes, rt) {
  const env = new Env(new Map(), rt.env)
  const cells = cellNodes.map(node => {
    const [name, formula] = node.fields
    env.define(name.value, new Thunk(name.value, formula, rt))
    return { name, formula }
  })
  return rt.inEnv(env, () =>
    record(
      sym('sheet'),
      ...cells.map(c =>
        record(
          sym('cell'),
          c.name,
          c.formula,
          env.binding(c.name.value).force()
        )
      )
    )
  )
}

// ================ default evaluator ================

// An evaluator with the standard command vocabulary installed.
export function makeEvaluator() {
  const ev = new BasslineEvaluator()
  const commands = {
    echo,
    set,
    fn,
    apply,
    sheet,
    '+': add,
    '-': sub,
    '*': mul,
    '/': div,
  }
  for (const [name, impl] of Object.entries(commands))
    ev.commands.set(name, impl)
  return ev
}
