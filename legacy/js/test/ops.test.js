import { describe, it, expect } from 'vitest'
import {
  eq,
  nil,
  int,
  text,
  symbol,
  bytes,
  list,
  record,
  dict,
  set,
  withMark,
} from '../src/data.js'
import {
  items,
  atoms,
  walk,
  marked,
  hasMark,
  isData,
  map,
  similar,
  prefixes,
  isHole,
  isAnon,
  hasHoles,
  extract,
  inject,
} from '../src/ops.js'
import { at, contains, assoc, dissoc } from '../src/data.js'

const s = symbol
const b = (...n) => bytes(Uint8Array.of(...n))

describe('walking', () => {
  const v = list([int(1n), dict([[s('k'), set([s('a')])]]), record([s('r')])])

  it('items yields the immediate constituents (dict as key, value, ...)', () => {
    expect([...items(v)].map(x => x.kind)).toEqual(['number', 'dict', 'record'])
    expect([...items(dict([[s('k'), int(1n)]]))].map(x => x.kind)).toEqual([
      'symbol',
      'number',
    ])
  })

  it('walk is deep, pre-order, document order', () => {
    expect(
      [...walk(list([int(1n), list([int(2n)])]))].map(x => x.kind)
    ).toEqual(['list', 'number', 'list', 'number'])
  })

  it('atoms yields only the leaves', () => {
    expect([...atoms(v)].map(x => x.kind)).toEqual([
      'number',
      'symbol',
      'symbol',
      'symbol',
    ])
  })

  it('walk is iterative — a very deep value does not overflow', () => {
    let deep = int(1n)
    for (let i = 0; i < 20000; i++) deep = list([deep])
    let count = 0
    for (const _ of walk(deep)) count++
    expect(count).toBe(20001)
  })
})

describe('the mark predicates', () => {
  it('marked / hasMark / isData', () => {
    expect(marked(withMark(int(1n)))).toBe(true)
    expect(marked(int(1n))).toBe(false)
    expect(hasMark(list([withMark(s('go'))]))).toBe(true)
    expect(hasMark(list([s('go')]))).toBe(false)
    expect(isData(list([s('go')]))).toBe(true)
    expect(isData(list([withMark(s('go'))]))).toBe(false)
  })
})

describe('map', () => {
  it('rebuilds a frame keeping the mark; leaves atoms alone', () => {
    const doubled = map(list([int(1n), int(2n)]), x =>
      int(BigInt(x.value) * 2n)
    )
    expect(eq(doubled, list([int(2n), int(4n)]))).toBe(true)
    const atom = int(7n)
    expect(map(atom, x => x)).toBe(atom) // an atom is returned unchanged
    const mk = map(withMark(list([int(1n)])), x => x)
    expect(marked(mk)).toBe(true)
  })

  it('maps dict entries as [key, value] pairs', () => {
    const d = dict([
      [s('a'), int(1n)],
      [s('b'), int(2n)],
    ])
    const flipped = map(d, ([k, v]) => [k, int(BigInt(v.value) + 10n)])
    expect(eq(at(flipped, s('a')), int(11n))).toBe(true)
    expect(eq(at(flipped, s('b')), int(12n))).toBe(true)
  })
})

describe('dict / set helpers', () => {
  it('at / contains on a dict and a set', () => {
    const d = dict([[s('k'), int(9n)]])
    expect(eq(at(d, s('k')), int(9n))).toBe(true)
    expect(at(d, s('z'))).toBeUndefined()
    expect(contains(d, s('k'))).toBe(true)

    const st = set([int(1n), int(2n)])
    expect(eq(at(st, int(1n)), int(1n))).toBe(true)
    expect(contains(st, int(3n))).toBe(false)
  })

  it('assoc / dissoc are non-destructive', () => {
    const d = dict([[s('a'), int(1n)]])
    const d2 = assoc(d, s('b'), int(2n))
    expect(d.size).toBe(1)
    expect(d2.size).toBe(2)
    expect(eq(dissoc(d2, s('a')), dict([[s('b'), int(2n)]]))).toBe(true)

    const st = set([int(1n)])
    expect(eq(assoc(st, int(2n)), set([int(1n), int(2n)]))).toBe(true)
    expect(eq(dissoc(set([int(1n), int(2n)]), int(2n)), set([int(1n)]))).toBe(
      true
    )
  })

  it('at refuses a non-collection', () => {
    // @ts-expect-error deliberate misuse
    expect(() => at(int(1n), int(1n))).toThrow()
  })
})

describe('similar', () => {
  it('matches on kind and mark; the exemplar frame may be shorter', () => {
    expect(
      similar(list([int(1n), int(2n), int(3n)]), list([nil(), nil()]))
    ).toBe(false) // wrong kinds inside
    expect(similar(list([int(1n), int(2n), int(3n)]), list([int(0n)]))).toBe(
      true
    ) // shorter exemplar, same kinds
    expect(similar(int(1n), int(999n))).toBe(true) // atoms: kind + mark only
    expect(similar(int(1n), withMark(int(1n)))).toBe(false) // mark differs
  })

  it('a record exemplar pins the head', () => {
    expect(similar(record([s('p'), int(1n)]), record([s('p')]))).toBe(true)
    expect(similar(record([s('p'), int(1n)]), record([s('q')]))).toBe(false)
  })

  it('a dict exemplar checks only the keys it names', () => {
    const v = dict([
      [s('a'), int(1n)],
      [s('b'), text('x')],
    ])
    expect(similar(v, dict([[s('a'), int(0n)]]))).toBe(true)
    expect(similar(v, dict([[s('a'), text('nope')]]))).toBe(false) // kind mismatch
    expect(similar(v, dict([[s('z'), int(0n)]]))).toBe(false) // missing key
  })

  it('a set exemplar checks membership', () => {
    expect(similar(set([int(1n), int(2n)]), set([int(1n)]))).toBe(true)
    expect(similar(set([int(1n)]), set([int(9n)]))).toBe(false)
  })
})

describe('prefixes', () => {
  it('scalars: only equals is a prefix', () => {
    expect(prefixes(int(1n), int(1n))).toBe(true)
    expect(prefixes(int(1n), int(2n))).toBe(false)
  })

  it('a leading run of a frame, last member itself a prefix', () => {
    expect(prefixes(list([]), list([int(1n)]))).toBe(true)
    expect(prefixes(list([int(1n)]), list([int(1n), int(2n)]))).toBe(true)
    expect(prefixes(list([int(9n)]), list([int(1n), int(2n)]))).toBe(false)
    expect(
      prefixes(list([list([int(1n)])]), list([list([int(1n), int(2n)])]))
    ).toBe(true)
  })

  it('dicts and sets compare in canonical order, not by inclusion', () => {
    const d = dict([
      [s('a'), int(1n)],
      [s('b'), int(2n)],
    ])
    expect(prefixes(dict([[s('a'), int(1n)]]), d)).toBe(true)
    expect(prefixes(dict([[s('b'), int(2n)]]), d)).toBe(false) // b is not the first key
    expect(prefixes(set([int(1n)]), set([int(1n), int(2n)]))).toBe(true)
  })

  it('implies cmp >= 0 (a prefix never sorts before the whole)', () => {
    const whole = list([int(1n), int(2n), int(3n)])
    const pre = list([int(1n), int(2n)])
    expect(prefixes(pre, whole)).toBe(true)
    expect(pre.compare(whole)).toBeGreaterThanOrEqual(0)
  })
})

describe('shapes', () => {
  it('isHole / isAnon / hasHoles', () => {
    expect(isHole(withMark(s('x')))).toBe(true)
    expect(isHole(s('x'))).toBe(false)
    expect(isHole(withMark(list([])))).toBe(false) // a frame is not a hole
    expect(isAnon(withMark(s('_')))).toBe(true)
    expect(isAnon(withMark(s('y')))).toBe(false)
    expect(hasHoles(list([int(1n), record([s('r'), withMark(s('h'))])]))).toBe(
      true
    )
    expect(hasHoles(list([int(1n), s('plain')]))).toBe(false)
  })

  it('extract binds holes and enforces repeats', () => {
    const shape = record([s('pt'), withMark(s('x')), withMark(s('y'))])
    const bnd = extract(shape, record([s('pt'), int(3n), int(4n)]))
    expect(bnd).toBeDefined()
    expect(eq(at(bnd, s('x')), int(3n))).toBe(true)
    expect(eq(at(bnd, s('y')), int(4n))).toBe(true)

    const same = record([s('eq'), withMark(s('n')), withMark(s('n'))])
    expect(extract(same, record([s('eq'), int(1n), int(1n)]))).toBeDefined()
    expect(extract(same, record([s('eq'), int(1n), int(2n)]))).toBeUndefined()
  })

  it('extract requires exact structure and returns undefined on a mismatch', () => {
    const shape = list([withMark(s('a')), withMark(s('b'))])
    expect(extract(shape, list([int(1n)]))).toBeUndefined() // wrong length
    expect(extract(shape, record([s('r'), int(1n), int(2n)]))).toBeUndefined()
  })

  it('the anonymous hole matches anything and binds nothing', () => {
    const bnd = extract(
      list([withMark(s('_')), withMark(s('keep'))]),
      list([b(1), int(7n)])
    )
    expect(bnd.size).toBe(1)
    expect(eq(at(bnd, s('keep')), int(7n))).toBe(true)
  })

  it('extract refuses a hole in a dict key', () => {
    expect(() =>
      extract(dict([[withMark(s('k')), withMark(s('v'))]]), dict([]))
    ).toThrow(/dict key/)
  })

  it('inject fills holes and leaves unbound ones in place; round-trips extract', () => {
    const shape = record([s('pt'), withMark(s('x')), withMark(s('y'))])
    const v = record([s('pt'), int(3n), int(4n)])
    const bnd = extract(shape, v)
    expect(eq(inject(shape, bnd), v)).toBe(true)

    const partial = inject(shape, dict([[s('x'), int(9n)]]))
    expect(eq(partial, record([s('pt'), int(9n), withMark(s('y'))]))).toBe(true)
  })
})
