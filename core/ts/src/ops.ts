import { readTemplate, type ReaderOptions } from './text/read.ts'
import {
  eq,
  isFrame,
  isValue,
  withMark,
  type Atom,
  type Factory,
  type Frame,
  type Value,
} from './types.ts'
import { value } from './values.ts'

export type Step =
  | { step: 'open'; value: Frame; depth: number }
  | { step: 'atom'; value: Atom; depth: number }
  | { step: 'close'; value: Frame; depth: number }

/** Every value in `root`, depth first: a frame opens, its members, it closes. */
export function* steps(root: Value): Generator<Step> {
  const open: { frame: Frame; members: Iterator<Value> }[] = []
  let next: Value | undefined = root
  while (true) {
    if (next !== undefined) {
      const depth = open.length
      if (isFrame(next)) {
        yield { step: 'open', value: next, depth }
        open.push({ frame: next, members: next.children() })
      } else {
        yield { step: 'atom', value: next, depth }
      }
    }
    const top = open.at(-1)
    if (top === undefined) return
    const r = top.members.next()
    if (r.done) {
      open.pop()
      yield { step: 'close', value: top.frame, depth: open.length }
      next = undefined
    } else {
      next = r.value
    }
  }
}

export function* walk(root: Value): Generator<Value> {
  for (const s of steps(root)) if (s.step !== 'close') yield s.value
}

export function fold<T>(root: Value, cb: (acc: T, curr: Value) => T, init: T) {
  let acc = init
  for (const value of walk(root)) {
    acc = cb(acc, value)
  }
  return acc
}

export const TO_VALUE = Symbol.for('bassline.blts.toValue')

type Entries = [Value, Value][]

export interface ToValue {
  [TO_VALUE](make: Factory): Value
}

/**
 * A host thing as a value, through `make`. A value passes as it is; an array
 * is a list of its members, each brought across in turn; an object with a
 * `[TO_VALUE]` method brings itself across; an integer (a number or a bigint)
 * is a number, a string is text, a JavaScript symbol is the symbol its
 * description spells, and a Uint8Array is bytes, copied. Anything else is
 * refused: there are no booleans, and nil is written, not left to `null` or
 * `undefined`.
 */
function toValue(make: Factory, x: unknown): Value {
  if (isValue(x)) return x
  if (Array.isArray(x)) {
    return make.list(x.map(e => toValue(make, e)))
  }
  if (typeof x === 'object' && x !== null && TO_VALUE in x) {
    const v = (x as ToValue)[TO_VALUE](make)
    if (!isValue(v)) throw new TypeError('[TO_VALUE] did not give a value')
    return v
  }
  switch (typeof x) {
    case 'bigint':
      return make.number(x)
    case 'number':
      if (!Number.isInteger(x)) throw new TypeError('not an integer: ' + x)
      return make.number(x)
    case 'string':
      return make.text(x)
    case 'symbol':
      let d = x.description
      if (d !== undefined) return make.sym(d)
  }
  if (x instanceof Uint8Array) return make.bytes(x.slice())
  throw new TypeError(
    `no reading of ${x === null ? 'null' : typeof x} as a value; ` +
      'splice a value, or give it a [TO_VALUE] method'
  )
}

export type Template = (
  strings: TemplateStringsArray,
  ...xs: unknown[]
) => Value

/**
 * A template tag reading the textual syntax as one value, built through
 * `make`. Each `${…}` splices in a value of its own, brought across by
 * `toValue`; a mark on the splice, `${x}!` or `!${x}`, marks it. The text is
 * read raw, so escapes mean what they mean in the textual syntax.
 */
export function template(make: Factory, opts?: ReaderOptions): Template {
  return (strings, ...xs) =>
    readTemplate(
      make,
      strings.raw,
      xs.map(x => toValue(make, x)),
      opts
    )
}

/** A value literal: `` bl`(point ${x} ${y})` ``. */
export const bl: Template = template(value)

export function ops(f: Factory = value) {
  function assoc(v: Value<'dict'>, ...vals: Entries): Value<'dict'>
  function assoc(v: Value<'set'>, ...vals: Value[]): Value<'set'>
  function assoc(v: Value<'set' | 'dict'>, ...vals: Entries | Value[]) {
    if (v.kind == 'dict') {
      return f.dict([...v.entries(), ...(vals as Entries)], v.mark)
    } else {
      return f.set([...v.children(), ...(vals as Value[])], v.mark)
    }
  }

  function dissoc(v: Value<'set' | 'dict'>, ...vals: Value[]) {
    const missing = (it: Value) => vals.findIndex(e => eq(it, e)) === -1
    if (v.kind === 'set') {
      return f.set(v.children().filter(missing), v.mark)
    } else {
      return f.dict(
        v.entries().filter(([k, v]) => missing(k)),
        v.mark
      )
    }
  }
  return {
    assoc,
    dissoc,
    withMark: (v: Value, mark = true) => withMark(f, v, mark),
    bl: template(f),
    toValue: (x: unknown) => toValue(f, x),
  } as const
}
