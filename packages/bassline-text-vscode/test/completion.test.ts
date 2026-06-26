import { describe, expect, it } from 'vitest'
import { symbolsIn } from '../src/completion'

describe('symbolsIn', () => {
  it('collects distinct symbols from a list', () => {
    expect(symbolsIn('[a b a]')?.sort()).toEqual(['a', 'b'])
  })
  it('includes the record head and dict keys', () => {
    expect(symbolsIn('<entry x>')?.sort()).toEqual(['entry', 'x'])
    expect(symbolsIn('{name: 1 host: 2}')?.sort()).toEqual(['host', 'name'])
  })
  it('excludes strings, numbers, and reserved literals', () => {
    expect(symbolsIn('<f "str" 42 true>')).toEqual(['f'])
  })
  it('excludes symbols that are not bare-safe', () => {
    expect(symbolsIn("'a b' c")).toEqual(['c'])
  })
  it('includes actionable symbol references', () => {
    expect(symbolsIn('`foo')).toEqual(['foo'])
  })
  it('returns null when the document does not parse', () => {
    expect(symbolsIn('[a')).toBeNull()
  })
})
