export const MSG: unique symbol
export const WORD: unique symbol

export type Guard<T> = (value: unknown) => value is T
export type Predicate = (value: unknown) => boolean
export type Scalar = number | string | boolean | null
export type Verb<M extends IMsg = IMsg> = (message: M) => unknown
export type Noun = Scalar | Record<string, unknown> | unknown[] | Word | IMsg
export type WordDefinition<N extends Noun = Noun, V extends Verb = Verb> =
  | { noun: N; verb?: V }
  | { noun?: N; verb: V }
export type WordInitializer = (word: Word) => void
export type MsgDefinition = Record<string, Word | WordDefinition>

export type NounBoundWord<N extends Noun = Noun> = Word<N, Verb> & {
  noun: N
}
export type VerbBoundWord<V extends Verb = Verb> = Word<Noun, V> & {
  verb: V
}
export type BoundWord = NounBoundWord | VerbBoundWord

export const is: {
  null: Guard<null>
  undefined: Guard<undefined>
  nan: Predicate

  number: Guard<number>
  string: Guard<string>
  boolean: Guard<boolean>
  array: Guard<unknown[]>

  object: Guard<Record<string, unknown>>
  fn: Guard<Function>

  word: Guard<Word>
  msg: Guard<IMsg>
  nbound: Guard<NounBoundWord>
  vbound: Guard<VerbBoundWord>
  bound: Guard<BoundWord>

  nil: Predicate
  scalar: Guard<Scalar>
  noun: Guard<Noun>
  verb: Guard<Verb>
}

export function word(): Word
export function word<N extends Noun, V extends Verb>(
  definition: WordDefinition<N, V>
): Word<N, V>
export function word(definition: WordInitializer): Word

export function noun<N extends Noun>(value: N): Word<N, Verb>
export function verb<V extends Verb>(value: V): Word<Noun, V>
export function msg(): Msg
export function msg(dict: undefined): Msg
export function msg(dict: MsgDefinition): Msg

export class Word<N extends Noun = Noun, V extends Verb = Verb> {
  readonly [WORD]: true
  noun?: N
  verb?: V

  constructor(definition?: WordDefinition<N, V> | WordInitializer)

  def(): this
  def<N2 extends Noun, V2 extends Verb>(
    definition: WordDefinition<N2, V2>
  ): this
}

export interface IMsg {
  readonly [MSG]: true
  words: Record<string, Word>

  word(key: string): Word
  define(key: string, definition: Word | WordDefinition): this
  defineWords(dict: MsgDefinition): this

  readonly entries: Array<[string, Word]>
  readonly nouns: Record<string, Noun>
  readonly verbs: Record<string, Verb>
}

export class Msg implements IMsg {
  readonly [MSG]: true
  words: Record<string, Word>

  constructor(dict?: MsgDefinition)

  word(key: string): Word
  define(key: string, definition: Word | WordDefinition): this
  defineWords(dict: MsgDefinition): this

  readonly entries: Array<[string, Word]>
  readonly nouns: Record<string, Noun>
  readonly verbs: Record<string, Verb>
}
