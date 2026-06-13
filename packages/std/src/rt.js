//import Bassline from '@bassline/core'

export function runtime(aClass) {
  return class extends aClass {
    constructor(...args) {
      super(...args)
      this.words = new Set()
      this.messages = new Set()
    }
    discard(v) {
      if (this.is.word(v)) {
        this.words.delete(v)
      }
      if (this.is.msg(v)) {
        this.messages.delete(v)
        for (const [_, aWord] of v) {
          this.discard(aWord)
        }
      }
    }
    word(n, v) {
      const w = super.word(n, v)
      this.words.add(w)
      return w
    }
    msg(def) {
      const m = super.msg(def)
      this.messages.add(m)
      return m
    }
  }
}

export class Runtime extends Bassline {}

export default runtime

function condPanic(...args) {
  throw new Error(`unhandled cond: ${String(args)}`)
}

function cond(cases, defaultFn = condPanic) {
  return (...args) => {
    for (const [p, f] of cases) {
      if (p(...args)) return f(...args)
    }
    return defaultFn(...args)
  }
}

function caseLambda(...fns) {
  const eqLen =
    f =>
    (...args) =>
      args.length === f.length
  return cond(fns.map(f => [eqLen(f), f]))
}

function defaultUpdate(state, change) {
  const { noun, verb } = change ?? {}
  if (noun) state.noun = noun
  if (verb) state.verb = verb
}

const word = (v, n) => {
  let state = { noun: n, verb: v }
  const update = change => defaultUpdate(state, change)
  return caseLambda(
    () => state.noun,
    aMsg => {
      state.verb(aMsg, state, update)
    },
    (aMsg, k) => {
      state.verb(aMsg, state, change => {
        update(change)
        k(change)
      })
    }
  )
}

const hasKeys = keys => aMsg => keys.every(k => k in aMsg)

const foo = word(
  cond([
    [
      hasKeys(['inc']),
      ({ inc }, { noun }, up) => {
        up({ noun: noun + inc })
      },
    ],
  ]),
  10
)

console.log(foo())

foo({ inc: 20 }, console.log)

console.log(foo())
