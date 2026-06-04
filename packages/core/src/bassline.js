// [[file:../../../book.org::*Utilities][Utilities:1]]
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
  nbound: v => is.word(v) && is.noun(v.noun),
  vbound: v => is.word(v) && is.verb(v.verb),
  bound: v => is.nbound(v) || is.vbound(v),

  nil: v => is.null(v) || is.undefined(v) || is.nan(v),
  scalar: v => is.number(v) || is.string(v) || is.null(v) || is.boolean(v),
  noun: v =>
    is.scalar(v) || is.object(v) || is.array(v) || is.word(v) || is.msg(v),
  verb: v => is.fn(v),
}

export const word = def => new Word(def)
export const noun = v => word({ noun: v })
export const verb = v => word({ verb: v })
export const msg = dict => new Msg(dict)
// Utilities:1 ends here

// [[file:../../../book.org::*Word Impl][Word Impl:1]]
export class Word {
  get [WORD]() {
    return true
  }
  constructor(definition) {
    if (is.undefined(definition)) return
    if (is.fn(definition)) definition(this)
    else if (
      is.object(definition) &&
      ('noun' in definition || 'verb' in definition)
    ) {
      this.def(definition)
    } else throw new Error(`Invalid word definition: ${String(definition)}`)
  }
  def(definition = {}) {
    if (!is.object(definition))
      throw new Error(`Invalid word definition: ${String(definition)}`)
    if ('noun' in definition) {
      const noun = definition.noun
      if (!is.noun(noun)) throw new Error(`Invalid noun: ${String(noun)}`)
      this.noun = noun
    }
    if ('verb' in definition) {
      const verb = definition.verb
      if (!is.verb(verb)) throw new Error(`Invalid verb: ${String(verb)}`)
      this.verb = verb
    }
    return this
  }
}
// Word Impl:1 ends here

// [[file:../../../book.org::*Msg Impl][Msg Impl:1]]
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
    } else if (is.object(aDef) && ('noun' in aDef || 'verb' in aDef)) {
      this.word(aKey).def(aDef)
    } else {
      throw new Error(`Invalid message word for ${aKey}`)
    }
    return this
  }
  defineWords(dict) {
    if (!is.object(dict))
      throw new Error(`Invalid message definition: ${String(dict)}`)
    for (const [k, v] of Object.entries(dict)) this.define(k, v)
    return this
  }
  get entries() {
    return Object.entries(this.words)
  }
  get nouns() {
    return Object.fromEntries(
      this.entries
        .filter(([_k, v]) => is.nbound(v))
        .map(([k, v]) => [k, v.noun])
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
// Msg Impl:1 ends here
