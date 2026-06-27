import { describe, expect, it } from 'vitest'
import { read } from '@bassline/core/text'
import {
  asNumber,
  asString,
  at,
  headSpelling,
  isComment,
  isDirective,
  paramsOf,
} from '../src/directives'

const one = (src: string) => read(src)[0]

describe('isDirective', () => {
  it('accepts an actionable record', () => {
    expect(isDirective(one('`(endpoint {port: 9000})'))).toBe(true)
  })
  it('accepts an actionable dict', () => {
    expect(isDirective(one('`{port: 9000}'))).toBe(true)
  })
  it('rejects a non-actionable record (it is content)', () => {
    expect(isDirective(one('(endpoint {port: 9000})'))).toBe(false)
  })
  it('rejects an actionable symbol (it is a reference, not a directive)', () => {
    expect(isDirective(one('`foo'))).toBe(false)
  })
})

describe('headSpelling', () => {
  it('reads the symbol head of a record', () => {
    expect(headSpelling(one('`(endpoint {port: 9000})'))).toBe('endpoint')
  })
  it('is undefined for a dict', () => {
    expect(headSpelling(one('`{port: 9000}'))).toBeUndefined()
  })
})

describe('isComment', () => {
  it('accepts an actionable comment directive', () => {
    expect(isComment(one('`(comment "drop me")'))).toBe(true)
  })
  it('rejects a non-actionable comment record (it is just data)', () => {
    expect(isComment(one('(comment "drop me")'))).toBe(false)
  })
  it('rejects a non-comment directive', () => {
    expect(isComment(one('`(endpoint {port: 9000})'))).toBe(false)
  })
})

describe('params extraction', () => {
  const d = one('`(endpoint {name: "deploy" host: "127.0.0.1" port: 9000})')
  const params = paramsOf(d)

  it('finds the parameter dict inside a record', () => {
    expect(params?.kind).toBe('dict')
  })
  it('reads string params', () => {
    expect(asString(at(params, 'name'))).toBe('deploy')
    expect(asString(at(params, 'host'))).toBe('127.0.0.1')
  })
  it('reads numeric params', () => {
    expect(asNumber(at(params, 'port'))).toBe(9000)
  })
  it('is undefined for a missing param', () => {
    expect(at(params, 'nope')).toBeUndefined()
  })
})
