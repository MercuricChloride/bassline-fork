import { fc, test } from '@fast-check/vitest'
import { describe, it, expect } from 'vitest'
import { BTree, BTreeSet } from '../../src/btree.js'

const numCmp = (a, b) => a - b

describe('BTree — Map interface', () => {
  it('get / set / has / size', () => {
    const t = new BTree(numCmp)
    expect(t.size).toBe(0)
    t.set(2, 'b').set(1, 'a').set(3, 'c')
    expect(t.size).toBe(3)
    expect(t.get(1)).toBe('a')
    expect(t.has(2)).toBe(true)
    expect(t.get(9)).toBeUndefined()
    expect(t.has(9)).toBe(false)
  })

  it('set overwrites on an equal key without growing', () => {
    const t = new BTree(numCmp)
    t.set(1, 'a').set(1, 'A')
    expect(t.size).toBe(1)
    expect(t.get(1)).toBe('A')
  })

  it('iterates entries / keys / values in key order', () => {
    const t = new BTree(numCmp, [
      [5, 'e'],
      [1, 'a'],
      [3, 'c'],
    ])
    expect([...t.keys()]).toEqual([1, 3, 5])
    expect([...t.values()]).toEqual(['a', 'c', 'e'])
    expect([...t]).toEqual([
      [1, 'a'],
      [3, 'c'],
      [5, 'e'],
    ])
  })

  it('forEach passes (value, key, tree)', () => {
    const seen = []
    new BTree(numCmp, [
      [2, 'b'],
      [1, 'a'],
    ]).forEach((v, k) => seen.push([k, v]))
    expect(seen).toEqual([
      [1, 'a'],
      [2, 'b'],
    ])
  })

  it('clone is independent', () => {
    const a = new BTree(numCmp, [[1, 'a']])
    const c = a.clone()
    c.set(2, 'b')
    expect(a.size).toBe(1)
    expect(c.size).toBe(2)
  })

  it('stays sorted across many splits (fanout is 32)', () => {
    const t = new BTree(numCmp)
    for (let i = 0; i < 500; i++) t.set((i * 37) % 500, i)
    expect(t.size).toBe(500)
    const keys = [...t.keys()]
    expect(keys).toEqual([...Array(500).keys()])
  })
})

describe('BTree — property vs Map', () => {
  test.prop([
    fc.array(fc.tuple(fc.integer({ min: -50, max: 50 }), fc.integer())),
  ])('matches a reference Map after the same inserts', ops => {
    const t = new BTree(numCmp)
    const ref = new Map()
    for (const [k, v] of ops) {
      t.set(k, v)
      ref.set(k, v)
    }
    expect(t.size).toBe(ref.size)
    for (const k of ref.keys()) expect(t.get(k)).toBe(ref.get(k))
    expect([...t.keys()]).toEqual([...ref.keys()].sort(numCmp))
  })
})

describe('BTreeSet — Set interface', () => {
  it('add / has / size / order', () => {
    const s = new BTreeSet(numCmp, [3, 1, 2, 1])
    expect(s.size).toBe(3)
    expect(s.has(2)).toBe(true)
    expect([...s]).toEqual([1, 2, 3])
    s.add(0)
    expect([...s.values()]).toEqual([0, 1, 2, 3])
  })

  it('entries yields [v, v] and forEach passes (v, v, set)', () => {
    const s = new BTreeSet(numCmp, [1, 2])
    expect([...s.entries()]).toEqual([
      [1, 1],
      [2, 2],
    ])
    const seen = []
    s.forEach((v, v2) => seen.push([v, v2]))
    expect(seen).toEqual([
      [1, 1],
      [2, 2],
    ])
  })

  it('clone is independent', () => {
    const a = new BTreeSet(numCmp, [1])
    const c = a.clone()
    c.add(2)
    expect(a.size).toBe(1)
    expect(c.size).toBe(2)
  })
})
