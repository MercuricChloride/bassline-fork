import { AssertionFailure } from '@bassline/core'
import { diff } from '../src/data/index.js'
import { ReSet } from '../src/reset.js'

const byId = value => value.id

describe('ReSet', () => {
  it('behaves like a set for basic operations and iteration', () => {
    const a = { id: 'a' }
    const b = { id: 'b' }
    const values = new ReSet([a])

    expect(values.size).toBe(1)
    expect([...values]).toEqual([a])
    expect(values.add(b)).toBe(values)
    expect(values.has(b)).toBe(true)
    expect(values.get(b)).toBe(b)
    expect([...values.values()]).toEqual([a, b])
    expect([...values.keys()]).toEqual([a, b])
    expect([...values.entries()]).toEqual([
      [a, a],
      [b, b],
    ])
    expect(values.delete(a)).toBe(true)
    expect(values.has(a)).toBe(false)
    expect(values.clear()).toBe(values)
    expect(values.size).toBe(0)
  })

  it('rejects undefined stored values', () => {
    expect(() => new ReSet([undefined])).toThrow(AssertionFailure)

    const values = new ReSet()
    expect(() => values.add(undefined)).toThrow(AssertionFailure)
    expect(() => values.reset([undefined])).toThrow(AssertionFailure)
  })

  it('deduplicates by identity projection', () => {
    const first = { id: 'a', version: 1 }
    const second = { id: 'a', version: 2 }
    const values = new ReSet([first], {
      identity: byId,
      merge: (_current, incoming) => incoming,
    })

    values.add(second)

    expect(values.size).toBe(1)
    expect(values.get(first)).toBe(second)
  })

  it('starts with an empty change set after construction', () => {
    const values = new ReSet([1, 2])
    expect(values.changes().data).toEqual({ add: [], remove: [] })
  })

  it('resets to exactly the provided values', () => {
    const values = new ReSet([1, 2])

    expect(values.reset([3])).toBe(values)

    expect(values.snapshot()).toEqual([3])
  })

  it('resets through a transform over previous and candidate values', () => {
    const values = new ReSet([1, 2])

    values.reset([3], (previous, next) => [...previous, ...next])

    expect(values.snapshot()).toEqual([1, 2, 3])
  })

  it('restores a checkpoint and accepts the same optional transform', () => {
    const values = new ReSet([1, 2])
    const restore = values.checkpoint()

    values.reset([3])
    restore((previous, captured) => [...captured, ...previous])

    expect(values.snapshot()).toEqual([1, 2, 3])
  })

  it('throws on duplicate identity without merge', () => {
    const values = new ReSet([{ id: 'a', version: 1 }], { identity: byId })

    expect(() => values.add({ id: 'a', version: 2 })).toThrow(AssertionFailure)
  })

  it('leaves state unchanged when reset sees a contradiction', () => {
    const original = { id: 'a', version: 1 }
    const values = new ReSet([original], { identity: byId })

    expect(() =>
      values.reset([
        { id: 'b', version: 1 },
        { id: 'b', version: 2 },
      ])
    ).toThrow(AssertionFailure)
    expect(values.snapshot()).toEqual([original])
  })

  it('merges duplicate identities', () => {
    const values = new ReSet([{ id: 'a', count: 1 }], {
      identity: byId,
      merge: (current, incoming) => ({
        id: current.id,
        count: current.count + incoming.count,
      }),
    })

    values.add({ id: 'a', count: 2 })

    expect(values.snapshot()).toEqual([{ id: 'a', count: 3 }])
  })

  it('throws when merge changes identity', () => {
    const values = new ReSet([{ id: 'a' }], {
      identity: byId,
      merge: () => ({ id: 'b' }),
    })

    expect(() => values.add({ id: 'a' })).toThrow(AssertionFailure)
  })

  it('throws when merge returns undefined', () => {
    const values = new ReSet([{ id: 'a' }], {
      identity: byId,
      merge: () => undefined,
    })

    expect(() => values.add({ id: 'a' })).toThrow(AssertionFailure)
  })

  it('leaves state unchanged when apply sees a contradiction', () => {
    const original = { id: 'a' }
    const values = new ReSet([original], { identity: byId })

    expect(() => values.apply(diff([{ id: 'b' }, { id: 'b' }], []))).toThrow(
      AssertionFailure
    )
    expect(values.snapshot()).toEqual([original])
  })

  it('applies diffs by adding first and removing second', () => {
    const existing = { id: 'a', version: 1 }
    const next = { id: 'a', version: 2 }
    const values = new ReSet([existing], {
      identity: byId,
      merge: (_current, incoming) => incoming,
    })

    values.apply(diff([next, { id: 'b' }], [{ id: 'a' }]))

    expect(values.snapshot()).toEqual([{ id: 'b' }])
  })

  it('lets same-identity add and remove cancel for absent entries', () => {
    const values = new ReSet([], {
      identity: byId,
      merge: (_current, incoming) => incoming,
    })

    values.apply(diff([{ id: 'a' }], [{ id: 'a' }]))

    expect(values.snapshot()).toEqual([])
  })

  it('removes by matching identity, not object identity', () => {
    const stored = { id: 'a' }
    const values = new ReSet([stored], { identity: byId })

    expect(values.delete({ id: 'a' })).toBe(true)

    expect(values.snapshot()).toEqual([])
  })

  it('reports net changes relative to the baseline', () => {
    const a = { id: 'a', version: 1 }
    const b = { id: 'b' }
    const c = { id: 'c' }
    const a2 = { id: 'a', version: 2 }
    const values = new ReSet([a, b], {
      identity: byId,
      merge: (_current, incoming) => incoming,
    })

    values.apply(diff([a2, c], [b]))

    expect(values.changes().data).toEqual({ add: [a2, c], remove: [a, b] })
  })

  it('drains net changes and clears the accumulated baseline', () => {
    const values = new ReSet([1])

    values.apply(diff([2], [1]))
    const drained = values.drain()

    expect(drained.data).toEqual({ add: [2], remove: [1] })
    expect(values.changes().data).toEqual({ add: [], remove: [] })
  })

  it('clones into a fresh baseline', () => {
    const values = new ReSet([1])
    values.add(2)

    const clone = values.clone()

    expect(clone).toBeInstanceOf(ReSet)
    expect(clone.snapshot()).toEqual([1, 2])
    expect(clone.changes().data).toEqual({ add: [], remove: [] })
  })

  it('performs identity-aware set theory operations', () => {
    const a = { id: 'a', version: 1 }
    const a2 = { id: 'a', version: 2 }
    const b = { id: 'b' }
    const c = { id: 'c' }
    const values = new ReSet([a, b], {
      identity: byId,
      merge: (_current, incoming) => incoming,
    })

    expect(values.union([a2, c]).snapshot()).toEqual([a2, b, c])
    expect(values.intersection([{ id: 'b' }, c]).snapshot()).toEqual([b])
    expect(values.difference([{ id: 'b' }, c]).snapshot()).toEqual([a])
    expect(values.symmetricDifference([b, c]).snapshot()).toEqual([a, c])
    expect(values.snapshot()).toEqual([a, b])
  })

  it('checks identity-aware set relationships', () => {
    const values = new ReSet([{ id: 'a' }, { id: 'b' }], {
      identity: byId,
    })

    expect(values.isSubsetOf([{ id: 'a' }, { id: 'b' }, { id: 'c' }])).toBe(
      true
    )
    expect(values.isSubsetOf([{ id: 'a' }])).toBe(false)
    expect(values.isSupersetOf([{ id: 'a' }])).toBe(true)
    expect(values.isSupersetOf([{ id: 'a' }, { id: 'c' }])).toBe(false)
    expect(values.isDisjointFrom([{ id: 'c' }])).toBe(true)
    expect(values.isDisjointFrom([{ id: 'b' }])).toBe(false)
    expect(values.equals([{ id: 'b' }, { id: 'a' }])).toBe(true)
    expect(values.equals([{ id: 'a' }])).toBe(false)
  })

  it('maps into a new ReSet with optional identity policy', () => {
    const values = new ReSet(
      [
        { id: 'a', score: 1 },
        { id: 'b', score: 2 },
      ],
      { identity: byId }
    )

    const mapped = values.map(
      (value, key, set) => ({
        name: key,
        score: value.score * set.size,
      }),
      { identity: value => value.name }
    )

    expect(mapped.snapshot()).toEqual([
      { name: 'a', score: 2 },
      { name: 'b', score: 4 },
    ])
    expect(mapped.has({ name: 'a' })).toBe(true)
    expect(mapped.changes().data).toEqual({ add: [], remove: [] })
  })

  it('filters into a new ReSet with the same identity policy', () => {
    const values = new ReSet(
      [
        { id: 'a', keep: true },
        { id: 'b', keep: false },
      ],
      { identity: byId }
    )

    const filtered = values.filter((_value, key) => key === 'a')

    expect(filtered.snapshot()).toEqual([{ id: 'a', keep: true }])
    expect(filtered.has({ id: 'a' })).toBe(true)
  })

  it('reduces values with identity keys', () => {
    const values = new ReSet(
      [
        { id: 'a', score: 1 },
        { id: 'b', score: 2 },
      ],
      { identity: byId }
    )

    const total = values.reduce(
      (acc, value, key) => acc + value.score + key.length,
      0
    )

    expect(total).toBe(5)
  })

  it('reduces without an initial value and rejects empty reductions', () => {
    const values = new ReSet([1, 2, 3])

    expect(values.reduce((acc, value) => acc + value)).toBe(6)
    expect(() => new ReSet().reduce(acc => acc)).toThrow(AssertionFailure)
  })

  it('supports key-aware forEach, some, every, and find', () => {
    const values = new ReSet([{ id: 'a' }, { id: 'b' }], { identity: byId })
    const seen = []

    values.forEach((_value, key, set) => seen.push([key, set.size]))

    expect(seen).toEqual([
      ['a', 2],
      ['b', 2],
    ])
    expect(values.some((_value, key) => key === 'b')).toBe(true)
    expect(values.every(value => value.id.length === 1)).toBe(true)
    expect(values.find((_value, key) => key === 'b')).toEqual({ id: 'b' })
    expect(values.find((_value, key) => key === 'c')).toBeUndefined()
  })
})
