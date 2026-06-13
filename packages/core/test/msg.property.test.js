import { fc, test } from '@fast-check/vitest'
import { describe, expect, it } from 'vitest'
import { is, msg, noun, verb } from '../src/bassline.js'

const scalar = fc.oneof(
  fc.double({ noNaN: true }),
  fc.string(),
  fc.boolean(),
  fc.constant(null)
)
const sendA = () => {}
const sendB = () => {}
const wordSpec = fc.oneof(
  scalar.map(value => ({ input: noun(value), noun: value })),
  scalar.map(value => ({ input: { noun: value }, noun: value })),
  fc.constant({ input: verb(sendA), verb: sendA }),
  fc.constant({ input: { verb: sendB }, verb: sendB }),
  scalar.map(value => ({ input: { noun: value, verb: sendA }, noun: value, verb: sendA }))
)
const invalidMessageValue = fc.oneof(
  scalar,
  fc.array(scalar),
  fc.dictionary(fc.string(), scalar).filter(v => !('noun' in v) && !('verb' in v)),
  fc.func(fc.anything())
)

describe('Msg', () => {
  it('creates empty messages for omitted or undefined dictionaries', () => {
    expect(msg().entries).toEqual([])
    expect(msg(undefined).entries).toEqual([])
  })

  it('stores words in a null-prototype dictionary', () => {
    expect(Object.getPrototypeOf(msg().words)).toBe(null)
  })

  test.prop([fc.string()])('word lookup is stable', key => {
    const m = msg()
    expect(m.word(key)).toBe(m.word(key))
  })

  test.prop([fc.dictionary(fc.string(), wordSpec)])(
    'word dictionaries project entries, nouns, and verbs',
    spec => {
      const dict = Object.fromEntries(
        Object.entries(spec).map(([key, value]) => [key, value.input])
      )
      const m = msg(dict)
      const expectedNouns = Object.create(null)
      const expectedVerbs = Object.create(null)

      for (const [key, value] of Object.entries(spec)) {
        if ('noun' in value) expectedNouns[key] = value.noun
        if ('verb' in value) expectedVerbs[key] = value.verb
      }

      expect(Object.keys(m.words).sort()).toEqual(Object.keys(spec).sort())
      expect(m.nouns).toEqual(expectedNouns)
      expect(Object.keys(m.verbs).sort()).toEqual(Object.keys(expectedVerbs).sort())
      for (const [key, value] of Object.entries(expectedVerbs)) {
        expect(m.verbs[key]).toBe(value)
      }
    }
  )

  test.prop([invalidMessageValue])(
    'direct non-word values are rejected in message dictionaries',
    value => {
      expect(() => msg({ value })).toThrow(/Invalid message word/)
    }
  )

  it('rejects accidental data objects unless wrapped as nouns', () => {
    expect(() => msg({ x: 1 })).toThrow(/Invalid message word/)
    expect(() => msg({ x: { label: 'accidental data object' } })).toThrow(
      /Invalid message word/
    )
    expect(() => msg({ x: { noun: undefined } })).toThrow(/Invalid noun/)
    expect(msg({ x: { noun: { label: 'intentional noun' } } }).nouns.x).toEqual({
      label: 'intentional noun',
    })
  })

  it('treats reserved-looking spellings as ordinary keys', () => {
    const m = msg({
      via: noun('route'),
      loadMessage: { noun: msg({ ok: noun(true) }) },
    })

    expect(m.nouns.via).toBe('route')
    expect(is.msg(m.nouns.loadMessage)).toBe(true)
  })
})
