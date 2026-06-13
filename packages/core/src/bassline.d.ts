export const MSG: unique symbol
export const WORD: unique symbol
export const BASSLINE: unique symbol

export type Guard<T = any> = (value: unknown) => value is T
export type Predicate = (value: unknown) => boolean

export type Scalar = number | string | boolean | null
export type Noun = any
export type Verb = (message: Msg) => any

export interface Word<N = any, V = any> {
  readonly [WORD]: true
  noun: N
  verb?: V
}

export interface Msg {
  readonly [MSG]: true
  [key: string]: any
  [Symbol.iterator](): IterableIterator<[string, Word]>
}

export interface WordProto {
  readonly [WORD]: true
}

export interface MsgProto {
  readonly [MSG]: true
  [Symbol.iterator](): IterableIterator<[string, Word]>
}

export const wordProto: WordProto
export const msgProto: MsgProto

export interface Recognition {
  null: Guard<null>
  undefined: Guard<undefined>
  nan: Predicate

  number: Guard<number>
  string: Guard<string>
  boolean: Guard<boolean>
  array: Guard<any[]>

  object: Guard<Record<string, any>>
  fn: Guard<Function>

  bassline: Guard<Bassline>
  word: Guard<Word>
  msg: Guard<Msg>
  nbound: Guard<Word>
  vbound: Guard<Word>
  bound: Guard<Word>

  nil: Predicate
  scalar: Guard<Scalar>
  noun: Guard<Noun>
  verb: Guard<Verb>
}

export const is: Recognition

export interface Bassline {
  readonly [BASSLINE]: true
  readonly is: Recognition

  readonly fresh: this
  readonly reference: this

  derive<T = any>(fn: (bassline: this) => T): T
  extend<T extends object = any>(fn: (bassline: this) => T): this & T

  word<N = any, V = any>(noun: N, verb?: V): Word<N, V>
  verb<V extends Verb = Verb>(verb: V): Word<null, V>
  msg<T = any>(dict?: T): Msg
}

export interface BasslineRoot extends Omit<Bassline, 'fresh' | 'extend'> {
  readonly fresh: Bassline
}

export const bassline: BasslineRoot
export default bassline
