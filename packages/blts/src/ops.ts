import { isFrame, type Atom, type Frame, type Value } from './types.ts'

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
