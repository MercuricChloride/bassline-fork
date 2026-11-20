// What objects answer, and the names things go by. A port of the second half
// of blnim's queries/queries.nim.
//
// An object is a marked set: the mark says it is a thing to bring about
// here, not just data. Its members are records shaped as answers: an
// unmarked (QUESTION ANSWER) is something it answers, and a marked
// !(QUESTION ANSWER) is an order, such as its kinds, !(kind K), which
// together say how to bring it about, or a send's !(to ID).
//
//   !{!(kind search-space) (identity s1) (holds {(alice 1)})}
//   !{!(kind note) (identity 0x9f3a…) (text "hi")}
//   !{(identity p1) (identity 0x9f3a…) (address "10.0.0.1")}
//
// So what an object answers is a query over its members: its records under a
// head, of width two, and their one field, found by bisecting. An object with
// no kinds is a description to find a thing by. What it is called is its
// answers to `identity`, one per name; two things are the same for a reader
// when a name of one is a name of the other, and learning more about a thing
// is a union. A value that isn't an object is a name of its own.

import { ledBy } from './shape.ts'
import { just } from './stream.ts'
import { eq, type Factory, type Value } from './types.ts'
import { value } from './values.ts'

/** A record of width two, read as what it answers. */
export type AnswerRecord = { question: Value; answer: Value }

/** Whether `v` is an object: a marked set. */
export const isObject = (v: Value): v is Value<'set'> =>
  v.kind === 'set' && v.mark

/** A record of width two as an answer, or undefined for anything else. */
export function toAnswer(v: Value): AnswerRecord | undefined {
  if (v.kind !== 'record' || v.length !== 2) return undefined
  return { question: v.items[0]!, answer: v.items[1]! }
}

/** A set's records under `head`, unmarked or marked, in CE order. */
export function headed(set: Value<'set'>, head: Value, marked = false) {
  return ledBy(set, 'record', [head], marked)
}

function* under(o: Value, question: Value, marked: boolean) {
  if (!isObject(o)) return
  for (const r of headed(o, question, marked)) {
    const a = toAnswer(r)
    if (a !== undefined) yield a.answer
  }
}

/** What an object answers to `question`, in CE order. */
export const answers = (o: Value, question: Value) => under(o, question, false)

/**
 * An answer an object gives to `question`, for a consumer that wants one: the
 * first, in CE order.
 */
export function answer(o: Value, question: Value): Value | undefined {
  for (const a of answers(o, question)) return a
  return undefined
}

/** An object's orders under `question`, !(QUESTION ANSWER), in CE order. */
export const orders = (o: Value, question: Value) => under(o, question, true)

/** Objects and names, built through the factory `f`. */
export function objects(f: Factory = value) {
  const q = {
    identity: f.sym('identity'),
    /** a composite's parts, in order */
    parts: f.sym('parts'),
    /** what a space holds */
    holds: f.sym('holds'),
    /** how to bring a thing about: !(kind K), marked */
    kind: f.sym('kind'),
    /** where a send sends: !(to ID), marked */
    to: f.sym('to'),
  } as const

  /** An object of these members: answers and orders. */
  const obj = (...members: Value[]) => f.set(members, true)

  /** (QUESTION ANSWER): something answered. */
  const answered = (question: Value, answer: Value) =>
    f.record([question, answer])

  /** !(QUESTION ANSWER): an order, not just something answered. */
  const order = (question: Value, answer: Value) =>
    f.record([question, answer], true)

  /** !(to ID): an order to send to the thing going by `id`. */
  const target = (id: Value) => order(q.to, id)

  /** The IDs an object's !(to ID) orders send to. */
  const targets = (o: Value) => orders(o, q.to)

  /** An object's kinds, from its !(kind K) orders. */
  const kinds = (o: Value) => orders(o, q.kind)

  /** Whether an object has this kind among its kinds. */
  const hasKind = (o: Value, kind: Value) =>
    isObject(o) && o.has(order(q.kind, kind))

  /** The names an ID goes by: an object's answers to `identity`, or a value that isn't an object, alone. */
  const identities = (id: Value): Iterable<Value> =>
    isObject(id) ? answers(id, q.identity) : just(id)

  /** Whether an ID goes by `name`. */
  const knownAs = (id: Value, name: Value) =>
    isObject(id) ? id.has(answered(q.identity, name)) : eq(id, name)

  /** Whether two IDs speak of the same thing: a name of one is a name of the other. */
  function sharesIdentity(a: Value, b: Value) {
    for (const name of identities(a)) if (knownAs(b, name)) return true
    return false
  }

  function* identityAnswers(id: Value) {
    for (const name of identities(id)) yield answered(q.identity, name)
  }

  /** An object that is only names: one (identity NAME) per name, an object among them giving its own. */
  const identity = (...names: Value[]) =>
    obj(...names.flatMap(n => [...identityAnswers(n)]))

  /** The names alone of a thing: an object's identity answers as an object, or a value that isn't an object, itself. */
  const identityOf = (v: Value) =>
    isObject(v) ? obj(...identityAnswers(v)) : v

  /** An identity of sixteen random bytes, for a thing nobody else has named. */
  const randomId = () =>
    identity(f.bytes(crypto.getRandomValues(new Uint8Array(16))))

  /** `o` with more names, everything else it answers kept. */
  const alsoKnownAs = (o: Value, ...more: Value[]) =>
    obj(
      ...(isObject(o) ? o.children() : identityAnswers(o)),
      ...more.flatMap(n => [...identityAnswers(n)])
    )

  /** An object of these kinds, going by `id`'s names, answering `more`. */
  const describe = (ks: Value[], id: Value, ...more: Value[]) =>
    obj(...ks.map(k => order(q.kind, k)), ...identityAnswers(id), ...more)

  return {
    q,
    obj,
    answered,
    order,
    target,
    targets,
    kinds,
    hasKind,
    identities,
    knownAs,
    sharesIdentity,
    identity,
    identityOf,
    randomId,
    alsoKnownAs,
    describe,
  } as const
}
