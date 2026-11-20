import { describe, expect, it } from 'vitest'
import {
  bl,
  encode,
  eq,
  print,
  ReadError,
  readValue,
  template,
  TO_VALUE,
  value,
  type Factory,
  type Value,
} from '../src/index.ts'
import { randValue } from './random.ts'

const same = (a: Value, b: Value) => expect(eq(a, b))
const read = (t: string) => readValue(value, t)

describe('bl', () => {
  it('reads the textual syntax as one value', () => {
    same(
      bl`(f [1 2] {a: "x"} 0xdead go!)`,
      read('(f [1 2] {a: "x"} 0xdead go!)')
    )
  })

  it('reads the text raw, so escapes mean what they mean in the syntax', () => {
    same(bl`"a\nb\t\"c\""`, value.text('a\nb\t"c"'))
  })

  it('splices any value in as a value of its own', () => {
    for (let n = 0; n < 100; n++) {
      const v = randValue(3)
      same(bl`(got ${v})`, value.record([value.sym('got'), v]))
    }
    const x = value.sym('x')
    same(bl`[a${x}b]`, read('[a x b]'))
    same(bl`{${x}: 1}`, read('{x: 1}'))
  })

  it('brings host integers, strings and bytes across', () => {
    same(
      bl`(p ${5} ${10n ** 30n} ${'hi'} ${Uint8Array.of(1, 2)})`,
      read('(p 5 1000000000000000000000000000000 "hi" 0x0102)')
    )
  })

  it('copies spliced bytes', () => {
    const b = Uint8Array.of(1)
    const v = bl`${b}` as Value<'bytes'>
    b[0] = 9
    expect(v.payload[0]).toBe(1)
  })

  it('brings an object across through its [TO_VALUE] method', () => {
    const point = {
      x: 3,
      [TO_VALUE]: (m: Factory) => m.record([m.sym('point'), m.number(3)]),
    }
    same(bl`[${point}]`, read('[(point 3)]'))
  })

  it('marks a splice marked in front or behind, and keeps a mark it came with', () => {
    same(
      bl`[${value.sym('go')}! !${bl`(f)`} ${value.sym('a', true)}]`,
      read('[go! !(f) a!]')
    )
  })

  it('refuses what it cannot read', () => {
    const x = value.sym('x')
    for (const f of [
      () => bl`"${x}"`,
      () => bl`'${x}'`,
      () => bl`; ${x}
        1`,
      () => bl`!${x}!`,
      () => bl`${x}!a`,
      () => bl`${x} ${x}`,
      () => bl``,
      () => bl`￼`,
    ])
      expect(f).toThrow(ReadError)
    for (const f of [
      () => bl`${true}`,
      () => bl`${null}`,
      () => bl`${undefined}`,
      () => bl`${1.5}`,
      () => bl`${{}}`,
    ])
      expect(f).toThrow(TypeError)
  })

  it('builds through the factory it is given', () => {
    const made: string[] = []
    const spy = template({
      ...value,
      list: (items = [], mark = false) => (
        made.push('list'),
        value.list(items, mark)
      ),
    })
    expect(print(spy`[${value.sym('a')} [b]]`)).toBe('[a [b]]')
    expect(made).toEqual(['list', 'list'])
  })
})
