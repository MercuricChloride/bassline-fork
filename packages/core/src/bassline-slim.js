export const MSG = Symbol.for('$$BASSLINE_MSG$$')
export const WORD = Symbol.for('$$BASSLINE_WORD$$')

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

  word: v => is.object(v) && v[WORD],
  msg: v => is.object(v) && v[MSG],
  bound: v => is.word(v) && is.noun(v.noun),
  vbound: v => is.word(v) && is.verb(v.verb),

  nil: v => is.null(v) || is.undefined(v) || is.nan(v),
  scalar: v => is.number(v) || is.string(v) || is.null(v) || is.boolean(v),
  noun: v =>
    is.scalar(v) || is.object(v) || is.array(v) || is.word(v) || is.msg(v),
  verb: v => is.fn(v),
}

export function word(definition) {
  return new Word(definition)
}
export function noun(value) {
  return new Word({ noun: value })
}
export function verb(value) {
  return new Word({ verb: value })
}
export function msg(dict) {
  return new Msg(dict)
}

export class Word {
  get [WORD]() {
    return true
  }
  constructor(definition = {}) {
    if (is.fn(definition)) definition(this)
    else if (is.object(definition)) this.def(definition)
    else throw new Error(`Invalid word definition: ${definition}`)
  }
  def({ noun, verb } = {}) {
    if (noun !== undefined) this.noun = noun
    if (verb !== undefined) this.verb = verb
    return this
  }
}

export class Msg {
  get [MSG]() {
    return true
  }
  words = Object.create(null)
  constructor(dict = {}) {
    this.defineWords(dict)
  }
  word(aKey) {
    if (!this.words[aKey]) this.words[aKey] = word()
    return this.words[aKey]
  }
  define(aKey, aDef) {
    if (is.word(aDef)) {
      this.words[aKey] = aDef
    } else {
      this.word(aKey).def(aDef)
    }
    return this
  }
  defineWords(dict) {
    for (const [k, v] of Object.entries(dict)) this.define(k, v)
    return this
  }
  get entries() {
    return Object.entries(this.words)
  }
  get nouns() {
    return Object.fromEntries(
      this.entries.filter(([_k, v]) => is.bound(v)).map(([k, v]) => [k, v.noun])
    )
  }
  get verbs() {
    return Object.fromEntries(
      this.entries
        .filter(([_k, v]) => is.vbound(v))
        .map(([k, v]) => [k, v.verb])
    )
  }
}
