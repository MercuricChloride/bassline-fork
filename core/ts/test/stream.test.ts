import { describe, expect, it } from 'vitest'
import {
  alt,
  altFrom,
  cat,
  catFrom,
  empty,
  filterMap,
  just,
  lazy,
  merge,
  pull,
  stream,
  tap,
} from '../src/index.ts'

function* count(from = 0) {
  for (let i = from; ; i++) yield i
}
function* letters(s: string) {
  yield* s
}

describe('streams', () => {
  it('have the platform helpers', () => {
    expect(
      count()
        .filter(n => n % 2 === 0)
        .map(n => n * 10)
        .take(3)
        .toArray()
    ).toEqual([0, 20, 40])
    expect(
      stream([1, 2, 3])
        .map(n => n + 1)
        .toArray()
    ).toEqual([2, 3, 4])
  })

  it('pull leaves the stream open; the platform take closes it', () => {
    const s = count()
    expect(pull(s, 2)).toEqual([0, 1])
    expect(pull(s)).toBe(2)
    expect(pull(s, 2)).toEqual([3, 4])
    const t = count()
    expect(t.take(2).toArray()).toEqual([0, 1])
    expect(pull(t)).toBe(undefined)
    expect(pull(empty())).toBe(undefined)
  })

  it('just, empty, lazy', () => {
    expect([...just(1)]).toEqual([1])
    expect([...empty()]).toEqual([])
    let made = 0
    const s = lazy(() => (made++, [1, 2]))
    expect(made).toBe(0)
    expect([...s]).toEqual([1, 2])
    expect(made).toBe(1)
  })

  it('alt takes fair turns, so an endless stream starves nothing', () => {
    expect(pull(alt(count(), letters('ab'), [true]), 6)).toEqual([
      0,
      'a',
      true,
      1,
      'b',
      2,
    ])
    expect([...alt([1, 2, 3], [], ['x'])]).toEqual([1, 'x', 2, 3])
  })

  it('altFrom admits a stream a round, so an endless supply starves nothing', () => {
    function* supply() {
      for (let i = 0; ; i++) yield just(i)
    }
    expect(pull(altFrom(supply()), 4)).toEqual([0, 1, 2, 3])
    function* endless() {
      yield count(100)
      yield letters('ab')
    }
    expect(pull(altFrom(endless()), 5)).toEqual([100, 101, 'a', 102, 'b'])
  })

  it('cat and catFrom: one after another', () => {
    expect([...cat([1, 2], [], letters('a'))]).toEqual([1, 2, 'a'])
    expect([...catFrom([[1], [2, 3]])]).toEqual([1, 2, 3])
    expect(pull(cat(count(), letters('never')), 3)).toEqual([0, 1, 2])
  })

  it('merge keeps order, earlier stream first on a tie, pulling no further than taken', () => {
    const by = (a: number, b: number) => a - b
    expect([...merge(by, [1, 4, 6], [2, 4, 5], [])]).toEqual([1, 2, 4, 4, 5, 6])
    const pulled: number[] = []
    const watched = tap([1, 3, 5], n => pulled.push(n))
    const m = merge(by, watched, [2])
    expect(pull(m, 2)).toEqual([1, 2])
    expect(pulled).toEqual([1, 3])
  })

  it('filterMap passes over what it makes nothing of', () => {
    expect([
      ...filterMap([1, 2, 3, 4], n => (n % 2 ? undefined : n * n)),
    ]).toEqual([4, 16])
  })
})
