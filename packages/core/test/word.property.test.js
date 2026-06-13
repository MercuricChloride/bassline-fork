import { fc, test } from '@fast-check/vitest'
import { describe, expect, it } from 'vitest'
import { is, msg, noun, verb, word } from '../src/bassline.js'

const scalar = fc.oneof(
  fc.double({ noNaN: true }),
  fc.string(),
  fc.boolean(),
  fc.constant(null)
)
const validNoun = fc.oneof(
  scalar,
  fc.array(scalar),
  fc.dictionary(fc.string(), scalar),
  fc.constant(msg({ value: noun('message') }))
)
const invalidNoun = fc.oneof(
  fc.constant(undefined),
  fc.constant(Number.NaN),
  fc.constant(Symbol('x')),
  fc.bigInt(),
  fc.func(fc.anything())
)

describe('Word', () => {
  test.prop([validNoun])('noun(value) creates a noun-bound word', value => {
    const w = noun(value)
    expect(w.noun).toBe(value)
    expect(is.nbound(w)).toBe(true)
    expect(is.vbound(w)).toBe(false)
  })

  test.prop([fc.func(fc.anything())])(
    'verb(fn) creates a verb-bound word',
    fn => {
      const w = verb(fn)
      expect(w.verb).toBe(fn)
      expect(is.vbound(w)).toBe(true)
      expect(is.nbound(w)).toBe(false)
    }
  )

  test.prop([validNoun, validNoun])(
    'def returns the same word and preserves bindings',
    (a, b) => {
      const send = () => {}
      const w = noun(a)

      expect(w.def({ verb: send })).toBe(w)
      expect(w.noun).toBe(a)
      expect(w.verb).toBe(send)

      expect(w.def({ noun: b })).toBe(w)
      expect(w.noun).toBe(b)
      expect(w.verb).toBe(send)
    }
  )

  it('supports function initializers', () => {
    const send = () => {}
    const w = word(self => self.def({ noun: 'ready', verb: send }))

    expect(w.noun).toBe('ready')
    expect(w.verb).toBe(send)
  })

  test.prop([invalidNoun])('invalid noun definitions throw', value => {
    expect(() => noun(value)).toThrow(/Invalid noun/)
    expect(() => word({ noun: value })).toThrow(/Invalid noun/)
  })

  it('invalid verb definitions throw', () => {
    expect(() => verb(1)).toThrow(/Invalid verb/)
    expect(() => word({ verb: 'send' })).toThrow(/Invalid verb/)
    expect(() => word({ verb: undefined })).toThrow(/Invalid verb/)
  })

  it('rejects explicit empty or non-object definitions', () => {
    const empty = word()
    expect(empty.def()).toBe(empty)
    expect(() => word().def(1)).toThrow(/Invalid word definition/)
    expect(() => word({})).toThrow(/Invalid word definition/)
    expect(() => word(1)).toThrow(/Invalid word definition/)
  })
})
