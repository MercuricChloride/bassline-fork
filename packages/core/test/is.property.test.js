import { fc, test } from '@fast-check/vitest'
import { describe, expect, it } from 'vitest'
import { is, msg, noun, verb } from '../src/bassline.js'

const scalar = fc.oneof(
  fc.double({ noNaN: true }),
  fc.string(),
  fc.boolean(),
  fc.constant(null)
)
const plainObject = fc.dictionary(fc.string(), scalar)
const validNoun = fc.oneof(
  scalar,
  fc.array(scalar),
  plainObject,
  fc.constant(noun('word')),
  fc.constant(msg({ value: noun('message') }))
)

describe('is', () => {
  it('recognizes explicit edge cases', () => {
    expect(is.nil(null)).toBe(true)
    expect(is.nil(undefined)).toBe(true)
    expect(is.nil(Number.NaN)).toBe(true)
    expect(is.noun(Number.NaN)).toBe(false)
    expect(is.noun(undefined)).toBe(false)
    expect(is.noun(() => {})).toBe(false)
    expect(is.noun(Symbol('x'))).toBe(false)
    expect(is.array([])).toBe(true)
    expect(is.object([])).toBe(false)
  })

  test.prop([scalar])('scalars are nouns', value => {
    expect(is.scalar(value)).toBe(true)
    expect(is.noun(value)).toBe(true)
  })

  test.prop([plainObject])('plain objects are nouns but not arrays', value => {
    expect(is.object(value)).toBe(true)
    expect(is.array(value)).toBe(false)
    expect(is.noun(value)).toBe(true)
  })

  test.prop([fc.array(scalar)])('arrays are nouns but not objects', value => {
    expect(is.array(value)).toBe(true)
    expect(is.object(value)).toBe(false)
    expect(is.noun(value)).toBe(true)
  })

  test.prop([validNoun])('generated valid nouns satisfy is.noun', value => {
    expect(is.noun(value)).toBe(true)
  })

  test.prop([fc.func(fc.anything())])('functions are verbs, not nouns', fn => {
    expect(is.verb(fn)).toBe(true)
    expect(is.noun(fn)).toBe(false)
  })

  it('recognizes word and message bindings', () => {
    const n = noun('value')
    const v = verb(() => {})
    const both = noun('value').def({ verb: () => {} })
    const empty = msg().word('missing')

    expect(is.word(n)).toBe(true)
    expect(is.nbound(n)).toBe(true)
    expect(is.vbound(n)).toBe(false)
    expect(is.bound(n)).toBe(true)

    expect(is.vbound(v)).toBe(true)
    expect(is.nbound(v)).toBe(false)
    expect(is.bound(v)).toBe(true)

    expect(is.nbound(both)).toBe(true)
    expect(is.vbound(both)).toBe(true)
    expect(is.bound(empty)).toBe(false)
    expect(is.msg(msg())).toBe(true)
  })
})
