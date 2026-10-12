import { describe, expect, it } from 'vitest'
import { BTree, BTreeSet } from '../src/btree.ts'

const byNumber = (a: number, b: number) => a - b

describe('BTree', () => {
  it('keeps keys in order and one of each, through splits', () => {
    const keys = Array.from({ length: 5000 }, (_, i) => (i * 7919) % 5003)
    const t = new BTree<number, number>(byNumber)
    for (const k of keys) t.set(k, k * 2)
    for (const k of keys.slice(0, 100)) t.set(k, -k) // a later value for a key stands
    const sorted = [...new Set(keys)].sort(byNumber)
    expect([...t.keys()]).toEqual(sorted)
    expect(t.size).toBe(sorted.length)
    expect(t.get(keys[0]!)).toBe(-keys[0]!)
    expect(t.get(keys[200]!)).toBe(keys[200]! * 2)
    expect(t.has(5003)).toBe(false)
  })

  it('entriesFrom bisects to the first key a monotone bound holds for', () => {
    for (const n of [0, 1, 31, 32, 33, 1000, 5000]) {
      const s = new BTreeSet<number>(
        byNumber,
        Array.from({ length: n }, (_, i) => i * 2)
      )
      for (const bound of [
        -1,
        0,
        1,
        2,
        63,
        64,
        65,
        n,
        2 * n - 2,
        2 * n - 1,
        2 * n,
        3 * n,
      ]) {
        const want = [...s].filter(k => k >= bound)
        expect([...s.from(k => k >= bound)]).toEqual(want)
      }
    }
  })
})
