// [[file:../../../book.org::*Utilities][Utilities:1]]
export const MSG = Symbol.for('$$BASSLINE_MSG$$')
export const WORD = Symbol.for('$$BASSLINE_WORD$$')
export const BASSLINE = Symbol.for('$$BASSLINE$$')

export const is = {
  null: v => v === null,
  undefined: v => v === undefined,
  nan: v => Number.isNaN(v),
  number: v => typeof v === 'number' && !is.nan(v),
  string: v => typeof v === 'string',
  boolean: v => typeof v === 'boolean',
  array: v => Array.isArray(v),
  object: v => typeof v === 'object' && !is.null(v) && !is.array(v),
  fn: v => typeof v === 'function',

  bassline: v => is.object(v) && v[BASSLINE],
  word: v => is.object(v) && v[WORD],
  msg: v =>
    is.object(v) &&
    v[MSG] &&
    Object.entries(v).every(([k, v]) => is.string(k) && is.word(v)),
  nbound: v => is.word(v) && is.noun(v.noun),
  vbound: v => is.word(v) && is.verb(v.verb),
  bound: v => is.nbound(v) || is.vbound(v),

  nil: v => is.null(v) || is.undefined(v) || is.nan(v),
  scalar: v => is.number(v) || is.string(v) || is.null(v) || is.boolean(v),
  noun: v =>
    is.scalar(v) || is.object(v) || is.array(v) || is.word(v) || is.msg(v),
  verb: v => is.fn(v),
}

function condDefault(args) {
  throw new Error(`cond: No dispatch case for [${args}]`)
}
export function cond(cases, fallback = condDefault) {
  return (...args) => {
    for (const [predicate, fn] of cases) {
      if (predicate(...args)) return fn(...args)
    }
    return fallback(...args)
  }
}

export const caseLambda = (...fns) =>
  cond(fns.map(f => [(...args) => args.length === f.length, f]))

export class Word {
  get [WORD]() {
    return true
  }
}

export class Msg {
  get [MSG]() {
    return true
  }
  *[Symbol.iterator]() {
    for (const [k, v] of Object.entries(this)) yield [k, v]
  }
}

export class OtherBassline {
  words = new Map()
  word(n, v) {
    const id = crypto.randomUUID()
    this.words.set(id, { noun: n, verb: v })
    const aWord = caseLambda(
      () => this.words.get(id).noun,
      aMsg => {
        this.words.get(id).verb(aMsg)
      }
    )
    aWord.id = id
    aWord.bassline = this
    aWord[WORD] = true
    return aWord
  }
  msg(aFn) {
    return aFn((n, v) => this.word(n, v))
  }
}

export class Bassline {
  get [BASSLINE]() {
    return true
  }
  is = is
  word(n, v) {
    const wordHandler = {
      set: (target, prop, val) => {
        if (prop === 'noun' && !this.is.noun(val)) {
          throw new TypeError(`Invalid noun value: ${String(val)}`)
        }
        if (prop === 'verb' && !this.is.verb(val)) {
          throw new TypeError(`Invalid verb value: ${String(val)}`)
        }
        if (['verb', 'noun'].includes(prop)) {
          return Reflect.set(target, prop, val)
        }
        throw new TypeError(`Invalid word binding: ${String(prop)}`)
      },
    }
    const w = new Proxy(new Word(), wordHandler)
    w.noun = n
    if (v) w.verb = v
    return w
  }
  verb(fn) {
    return this.word(null, fn)
  }
  msg(dict = {}) {
    const msgHandler = {
      set: (target, prop, val) => {
        let w = val
        if (!this.is.word(val)) {
          if (this.is.noun(val)) {
            w = this.word(val)
          } else if (this.is.verb(val)) {
            w = this.word(null, val)
          } else {
            throw new TypeError(
              `Invalid message word! Key: ${String(prop)} value: ${String(val)}`
            )
          }
        }
        return Reflect.set(target, prop, w)
      },
    }
    const m = new Proxy(new Msg(), msgHandler)
    Object.assign(m, dict)
    return m
  }
  get reference() {
    return new Proxy(this, {
      get: (obj, key) => {
        const val = Reflect.get(obj, key)
        if (typeof val === 'function') {
          return val.bind(this)
        }
        return val
      },
    })
  }
  derive(fn) {
    return fn(this)
  }
  extend(...fns) {
    return fns.reduce((acc, aFn) => {
      const obj = aFn(acc)
      for (const k of Object.keys(obj)) {
        if (acc[k]) {
          console.warn(`overriding: ${k}`)
        }
      }
      Object.assign(acc, obj)
      return acc
    }, this)
  }
  static extend(...mixins) {
    return mixins.reduce((acc, aMixin) => aMixin(acc), this)
  }
}
export default Bassline
// Utilities:1 ends here

// [[file:../../../book.org::*Word Impl][Word Impl:1]]

// Word Impl:1 ends here

// [[file:../../../book.org::*Msg Impl][Msg Impl:1]]

// Msg Impl:1 ends here
