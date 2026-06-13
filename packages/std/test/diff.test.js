import { AssertionFailure, msg } from '@bassline/core'
import {
  assertDiff,
  diff,
  emptyDiff,
  filterDiff,
  invertDiff,
  isDiff,
  mapDiff,
} from '../src/data/index.js'

describe('diff', () => {
  it('defaults to empty add and remove arrays', () => {
    expect(diff().data).toEqual({ add: [], remove: [] })
  })

  it('preserves add and remove arrays', () => {
    const add = [1, 2]
    const remove = [3]
    const d = diff(add, remove)
    expect(d.get('add')).toBe(add)
    expect(d.get('remove')).toBe(remove)
  })

  it('validates add and remove arrays', () => {
    expect(() => diff('x', [])).toThrow(AssertionFailure)
    expect(() => diff([], 'x')).toThrow(AssertionFailure)
  })

  it('recognizes diff messages', () => {
    const d = diff([1], [2])
    expect(isDiff(d)).toBe(true)
    expect(assertDiff(d)).toBe(d)
    expect(isDiff(msg({ add: [], remove: [] }))).toBe(true)
    expect(isDiff(msg({ add: [] }))).toBe(false)
    expect(isDiff({ add: [], remove: [] })).toBe(false)
  })

  it('creates an empty diff on a target message', () => {
    const target = msg({ note: true })
    expect(emptyDiff(target)).toBe(target)
    expect(target.data).toEqual({ note: true, add: [], remove: [] })
  })

  it('inverts diffs', () => {
    const add = [1]
    const remove = [2]
    const inverted = invertDiff(diff(add, remove))
    expect(inverted.get('add')).toBe(remove)
    expect(inverted.get('remove')).toBe(add)
  })

  it('maps both sides of a diff', () => {
    const mapped = mapDiff(diff([1, 2], [3]), n => n * 2)
    expect(mapped.data).toEqual({ add: [2, 4], remove: [6] })
  })

  it('filters both sides of a diff', () => {
    const filtered = filterDiff(diff([1, 2, 3], [4, 5]), n => n % 2)
    expect(filtered.data).toEqual({ add: [1, 3], remove: [5] })
  })
})
