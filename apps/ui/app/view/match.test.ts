import { describe, expect, it } from 'vitest'
import { dict, int, record, str, sym } from '@bassline/core/data'
import { kind } from '@bassline/core/match'
import { at, dispatch, headed, keyed, sk } from './match'

describe('at / keyed (Data-land dict lookup)', () => {
  it('looks up by symbol key', () => {
    const d = dict([[sym('href'), str('https://example.com')]])
    expect(at(sk('href'))(d)).toBe(d.get(sym('href')))
    expect(at(sk('missing'))(d)).toBeUndefined()
  })

  it('looks up by NON-symbol key (arbitrary Value keys)', () => {
    const d = dict([[int(1), str('one')]])
    const found = at(int(1))(d)
    expect(found && kind.string(found) && found.value).toBe('one')
    expect(at(int(2))(d)).toBeUndefined()
  })

  it('at on a non-dict is undefined', () => {
    expect(at(sk('x'))(str('not a dict'))).toBeUndefined()
  })

  it('keyed recognizes presence and optional value predicate', () => {
    const d = dict([[sym('language'), str('forth')]])
    expect(keyed(sk('language'))(d)).toBe(true)
    expect(keyed(sk('language'), kind.string)(d)).toBe(true)
    expect(keyed(sk('language'), kind.int)(d)).toBe(false)
    expect(keyed(sk('nope'))(d)).toBe(false)
  })
})

describe('headed', () => {
  it('matches a record by head symbol name', () => {
    const node = record(sym('stack'), str('hi'))
    expect(headed('stack')(node)).toBe(true)
    expect(headed('text')(node)).toBe(false)
    expect(headed('stack')(str('not a record'))).toBe(false)
  })
})

describe('dispatch', () => {
  it('first matching rule wins, else fallback', () => {
    const fn = dispatch<null, string>(
      [
        [headed('a'), () => 'got a'],
        [kind.string, v => `string:${kind.string(v) ? v.value : ''}`],
      ],
      () => 'fallback'
    )
    expect(fn(record(sym('a')), null)).toBe('got a')
    expect(fn(str('hello'), null)).toBe('string:hello')
    expect(fn(int(7), null)).toBe('fallback')
  })
})
