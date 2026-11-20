import { describe, expect, it } from 'vitest'
import {
  encode,
  ops,
  print,
  value,
  type Factory,
  type Value,
} from '../src/index.ts'
import { randValue } from './random.ts'

const same = (a: Value, b: Value) => expect(encode(a)).toEqual(encode(b))
const { assoc, bl, dissoc, withMark } = ops()
const sym = (s: string) => value.sym(s)
const dict = (v: Value) => v as Value<'dict'>
const set = (v: Value) => v as Value<'set'>

describe('withMark', () => {
  it('sets and clears the mark, the rest as it was', () => {
    for (let n = 0; n < 200; n++) {
      const v = randValue(3)
      const flipped = withMark(v, !v.mark)
      expect(flipped.mark).toBe(!v.mark)
      same(withMark(flipped, v.mark), v)
    }
  })

  it('gives the same value back when the mark already matches', () => {
    const v = bl`(f [g])`
    expect(withMark(v, false)).toBe(v)
  })

  it('marks only the value, not what is inside it', () => {
    expect(print(withMark(bl`(f [g])`))).toBe('!(f [g])')
  })
})

describe('assoc', () => {
  it('adds entries to a dict, a later one for a key standing', () => {
    const d = dict(bl`{a: 1 b: 2}`)
    const d2 = assoc(
      d,
      [sym('a'), value.number(9)],
      [sym('c'), value.number(3)]
    )
    expect(print(d2)).toBe('{a: 9 b: 2 c: 3}')
    expect(print(d)).toBe('{a: 1 b: 2}')
  })

  it('adds members to a set, keeping one of each', () => {
    const s = set(bl`{x y}`)
    expect(print(assoc(s, sym('z'), sym('x')))).toBe('{x y z}')
    expect(print(s)).toBe('{x y}')
  })

  it('keeps the mark', () => {
    expect(assoc(dict(bl`!{a: 1}`), [sym('b'), value.nil()]).mark).toBe(true)
  })
})

describe('dissoc', () => {
  it('leaves keys out of a dict, and members out of a set', () => {
    const d = dict(bl`{a: 1 b: 2 c: 3}`)
    expect(print(dissoc(d, sym('a'), sym('c')))).toBe('{b: 2}')
    expect(print(dissoc(set(bl`{x y z}`), sym('y')))).toBe('{x z}')
    expect(print(d)).toBe('{a: 1 b: 2 c: 3}')
  })

  it('passes over what is not there, and keeps the mark', () => {
    expect(print(dissoc(set(bl`!{x}`), sym('q')))).toBe('!{x}')
  })
})

describe('ops over a factory', () => {
  it('builds through the factory it is given', () => {
    let made = 0
    const spy: Factory = {
      ...value,
      set: (xs, mark) => (made++, value.set(xs, mark)),
    }
    const o = ops(spy)
    o.assoc(set(bl`{x}`), sym('y'))
    o.withMark(bl`{x}`)
    o.bl`{a}`
    expect(made).toBe(3)
  })
})

describe('splicing host things', () => {
  it('reads an array as a list, its members brought across in turn', () => {
    expect(print(bl`(p ${[1, [2, 'x'], value.sym('a', true)]})`)).toBe(
      '(p [1 [2 "x"] a!])'
    )
    expect(print(bl`${[]}`)).toBe('[]')
  })

  it('reads a JavaScript symbol as the symbol its description spells', () => {
    expect(
      print(bl`[${Symbol('go')} ${Symbol('')} ${Symbol.for('a b')}]`)
    ).toBe("[go '' 'a b']")
    expect(() => bl`${Symbol()}`).toThrow(TypeError)
  })

  it('refuses an array holding something it cannot read', () => {
    expect(() => bl`${[1, true]}`).toThrow(TypeError)
  })
})
