import { describe, expect, it } from 'vitest'
import { BTreeSet } from '../src/btree.ts'
import {
  cmp,
  encode,
  eq,
  ops,
  pull,
  readValue,
  ShapeError,
  shapes,
  value,
  walk,
  type Shape,
  type Value,
} from '../src/index.ts'

const { bl, withMark } = ops()
const { shape, shapeFrom, shapeValue, fillings, inject } = shapes()

const read = (t: string) => readValue(value, t)
const sh = (t: string) => shapeFrom(read(t))
const fills = (s: Shape, t: string) => [...fillings(s, read(t))]
const dicts = (...ts: string[]) => ts.map(read)
const hex = (v: Value) => Buffer.from(encode(v)).toString('hex')
/** The same bindings, in the same order. */
const same = (a: Value[], b: Value[]) => expect(a.map(hex)).toEqual(b.map(hex))
/** The same bindings, in any order. */
const sameAs = (a: Value[], b: Value[]) =>
  expect(new Set(a.map(hex))).toEqual(new Set(b.map(hex)))

/** `set`, counting every member a search pulls from it. */
function counted(set: Value<'set'>) {
  const c = { pulls: 0, set }
  c.set = Object.assign(Object.create(set) as Value<'set'>, {
    *children() {
      for (const m of set.children()) {
        c.pulls++
        yield m
      }
    },
    *from(atOrAfter: (m: Value) => boolean) {
      for (const m of set.from(atOrAfter)) {
        c.pulls++
        yield m
      }
    },
  })
  return c
}

describe('fillings', () => {
  it("a plain shape fills a value with the example's members leading", () => {
    const file = sh('(shape (file name digest) {name digest})')
    same(
      fills(file, '(file "a.txt" 0xff extra)'),
      dicts('{name: "a.txt" digest: 0xff}')
    )
    expect(fills(file, '(dir "a.txt" 0xff)')).toEqual([])
    expect(fills(file, '(file)')).toEqual([])
  })

  it('a hole met again fits only what it is bound to', () => {
    const twice = sh('(shape [x y x] {x y})')
    same(fills(twice, '[1 2 1]'), dicts('{x: 1 y: 2}'))
    expect(fills(twice, '[1 2 3]')).toEqual([]) // no filling, not an error
  })

  it('a hole in a set member is tried against every member', () => {
    sameAs(
      fills(sh('(shape {(tag t)} {t})'), '{(tag a) (tag b) (other c)}'),
      dicts('{t: a}', '{t: b}')
    )
    const member = sh('(shape {a x} {x})')
    sameAs(fills(member, '{a b c}'), dicts('{x: a}', '{x: b}', '{x: c}'))
    expect(fills(member, '{b c}')).toEqual([]) // a literal member is still needed
    sameAs(
      fills(sh('(shape {[x] [y]} {x y})'), '{[1] [2]}'),
      dicts('{x: 1 y: 1}', '{x: 1 y: 2}', '{x: 2 y: 1}', '{x: 2 y: 2}')
    )
    // a hole that is a record is a hole, tried against every member of its mark
    sameAs(fills(sh('(shape {!(h)} {!(h)})'), '{plain beta! alpha!}'), [
      value.dict([[read('!(h)'), read('alpha!')]]),
      value.dict([[read('!(h)'), read('beta!')]]),
    ])
  })

  it('a hole in a dict key is tried against every entry', () => {
    sameAs(
      fills(sh('(shape {k: v} {k v})'), '{a: 1 b: 2}'),
      dicts('{k: a v: 1}', '{k: b v: 2}')
    )
    sameAs(
      fills(sh('(shape {k: k} {k})'), '{a: b c: c 1: 1}'),
      dicts('{k: c}', '{k: 1}')
    )
    same(
      fills(sh('(shape {(k x): 1} {x})'), '{(k 5): 1 (k 6): 2 (j 7): 1}'),
      dicts('{x: 5}')
    )
    same(fills(sh('(shape {a: x} {x})'), '{a: 1 b: 2}'), dicts('{x: 1}'))
  })

  it('marks must agree, and the wild fits anything and binds nothing', () => {
    same(
      fills(sh('(shape {(op x)} {x})'), '{(op go) (op go!)}'),
      dicts('{x: go}')
    )
    same(
      fills(sh('(shape {(op x!)} {x!})'), '{(op go) (op go!)}'),
      dicts('{x!: go!}')
    )
    expect(fills(sh('(shape !(f x) {x})'), '(f 1)')).toEqual([])
    const wild = sh('(shape {(p x) (q _)} {x} _)')
    same(fills(wild, '{(p 1) (q 1) (q 2)}'), dicts('{x: 1}')) // once, though two fit the wild
    expect(fills(wild, '{(p 1)}')).toEqual([])
  })

  it('answers each filling once, however many ways it is reached', () => {
    // x is 1 by way of [1 2] and by way of [1 3]
    same(
      fills(sh('(shape {[x _]} {x} _)'), '{[1 2] [1 3] [2 2]}'),
      dicts('{x: 1}', '{x: 2}')
    )
  })

  it('every hole must be bound', () => {
    expect(fills(sh('(shape (f x) {x y})'), '(f 1)')).toEqual([])
    expect(fills(sh('(shape [(k x)] {x (k x)})'), '[(k 1)]')).toEqual([]) // inside another hole
  })

  it('a search can start from bindings already had', () => {
    const row = sh('(shape (row label n) {label n})')
    same(
      [...fillings(row, bl`(row a 1)`, bl`{label: a}`)],
      [bl`{label: a n: 1}`]
    )
    expect([...fillings(row, bl`(row a 1)`, bl`{label: b}`)]).toEqual([])
    // what it doesn't bind rides along
    same(
      [...fillings(row, bl`(row a 1)`, bl`{seen: yes}`)],
      [bl`{label: a n: 1 seen: yes}`]
    )
    expect(() => fillings(row, bl`(row a 1)`, bl`[label a]`)).toThrow(
      ShapeError
    )
    expect(() => fillings(row, bl`(row a 1)`, bl`!{label: a}`)).toThrow(
      ShapeError
    )
  })

  it('nothing is worked out ahead of a pull', () => {
    const lists = value.set(Array.from({ length: 200 }, (_, i) => bl`[${i}]`))
    const three = sh('(shape {[x] [y] [z]} {x y z})')
    const first = pull(fillings(three, lists), 3) // eight million, three taken
    expect(new Set(first.map(hex)).size).toBe(3)
  })

  it('what the bindings decide is checked before anything branches', () => {
    const lists = counted(
      value.set(Array.from({ length: 1000 }, (_, i) => bl`[${i}]`))
    )
    // (stop) sorts after the lists; checked last, it would fail a million times
    expect([
      ...fillings(sh('(shape {(stop) [x] [y]} {x y})'), lists.set),
    ]).toEqual([])
    expect(lists.pulls).toBe(0)
    const graph: Value[] = []
    for (let i = 0; i < 1000; i++)
      graph.push(bl`(edge ${i} ${i + 1})`, bl`(node ${i})`)
    // each edge found by bisecting on the members bound already
    const path = sh('(shape {(edge x y) (edge y z) (node z)} {x y z})')
    const g = counted(value.set(graph))
    expect([...fillings(path, g.set)].length).toBe(998)
    expect(g.pulls).toBeLessThan(5000)
  })
})

describe('a shape as a search', () => {
  it('asked about a value, it answers every filling, and composes', () => {
    const row = sh('(shape (row label n) {label n})')
    const search = (v: Value) => fillings(row, v)
    same([...search(bl`(row a 1)`)], [bl`{label: a n: 1}`])
    expect(pull(search(bl`(note x)`))).toBe(undefined)
    const rows = [bl`(row a 1)`, bl`(note x)`, bl`(row b 2)`]
    same(rows.values().flatMap(search).toArray(), [
      bl`{label: a n: 1}`,
      bl`{label: b n: 2}`,
    ])
  })
})

describe('written down, and filled', () => {
  it('a shape reads and writes as (shape EXAMPLE {HOLE …} WILD)', () => {
    for (const t of ['(shape (f x) {x})', '(shape (f x _) {x} _)']) {
      expect(eq(shapeValue(sh(t)), read(t))).toBe(true)
    }
    for (const t of [
      '(shape (f x))',
      '(shape (f x) [x])',
      '!(shape (f x) {x})',
      '(form (f x) {x})',
    ]) {
      expect(() => sh(t)).toThrow(ShapeError)
    }
  })

  it('inject fills the holes bound, and leaves the rest', () => {
    const s = sh('(shape !{(cmd c): [arg x] other: y} {c x y})')
    expect(
      eq(inject(s, bl`{c: go x: 1}`), read('!{(cmd go): [arg 1] other: y}'))
    ).toBe(true)
    const filled = pull(fillings(s, read('!{(cmd go): [arg 1] other: 2}')))!
    expect(eq(inject(s, filled), read('!{(cmd go): [arg 1] other: 2}'))).toBe(
      true
    )
    expect(() => inject(s, bl`[c go]`)).toThrow(ShapeError)
  })
})

// ================ against a brute-force search ================

/** A small seeded generator; `rand(n)` is 0 to n, both included. */
function rng(seed: number) {
  let a = seed >>> 0
  return (n: number) => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    const u = ((t ^ (t >>> 14)) >>> 0) / 4294967296
    return Math.floor(u * (n + 1))
  }
}
type Rand = ReturnType<typeof rng>

const literal = (s: Shape, part: Value) =>
  walk(part).every(p => !s.holes.has(p) && !(s.wild && eq(s.wild, p)))

/**
 * What a filling is, said directly: under the bindings `b`, `v` fits `part`,
 * as quantifiers over the value's own keys and members.
 */
function fits(s: Shape, part: Value, v: Value, b: Value<'dict'>): boolean {
  if (s.wild && eq(s.wild, part)) return true
  if (s.holes.has(part)) {
    const w = b.get(part)
    return part.mark === v.mark && w !== undefined && eq(w, v)
  }
  if (part.kind !== v.kind || part.mark !== v.mark) return false
  switch (part.kind) {
    case 'list':
    case 'record': {
      const items = (v as Value<'list'>).items
      return (
        items.length >= part.items.length &&
        part.items.every((p, i) => fits(s, p, items[i]!, b))
      )
    }
    case 'dict': {
      const d = v as Value<'dict'>
      return part.entries().every(([key, item]) => {
        if (literal(s, key)) {
          const x = d.get(key)
          return x !== undefined && fits(s, item, x, b)
        }
        return d
          .entries()
          .some(([k, x]) => fits(s, key, k, b) && fits(s, item, x, b))
      })
    }
    case 'set': {
      const set = v as Value<'set'>
      return part
        .children()
        .every(m =>
          literal(s, m)
            ? set.has(m)
            : set.children().some(x => fits(s, m, x, b))
        )
    }
    default:
      return eq(part, v)
  }
}

/** Whether matching ever gets to `hole` in `part`: not under the wild, nor inside another hole. */
function reaches(s: Shape, hole: Value, part: Value): boolean {
  if (s.wild && eq(s.wild, part)) return false
  if (s.holes.has(part)) return eq(part, hole)
  if (
    part.kind === 'nil' ||
    part.kind === 'number' ||
    part.kind === 'text' ||
    part.kind === 'symbol' ||
    part.kind === 'bytes'
  )
    return false
  return part.children().some(p => reaches(s, hole, p))
}

/**
 * Every filling, by trying every assignment of the value's parts to the
 * holes: a hole binds what is in its place, so one of them, and of its own
 * mark. Undefined when there are more than `most` assignments to try.
 */
function bruteForce(
  s: Shape,
  v: Value,
  most = 20_000
): Set<string> | undefined {
  const holes = [...s.holes.children()]
  if (!holes.every(h => reaches(s, h, s.example))) return new Set()
  const parts = [...new BTreeSet<Value>(cmp, walk(v))]
  const candidates: Value[][] = []
  let tries = 1
  for (const h of holes) {
    candidates.push(parts.filter(p => p.mark === h.mark))
    tries *= Math.max(candidates.at(-1)!.length, 1)
    if (tries > most) return undefined
  }
  const found = new Set<string>()
  const assign = (i: number, b: [Value, Value][]) => {
    if (i === holes.length) {
      const binding = value.dict(b)
      if (fits(s, s.example, v, binding)) found.add(hex(binding))
      return
    }
    for (const c of candidates[i]!) assign(i + 1, [...b, [holes[i]!, c]])
  }
  assign(0, [])
  return found
}

/** Small values from a small alphabet, so parts repeat and shapes find several ways to fill. */
function small(r: Rand, depth = 0): Value {
  let v: Value
  if (depth >= 3 || r(depth === 0 ? 5 : 2) === 0) {
    v = [bl`0`, bl`1`, bl`2`, bl`a`, bl`b`, bl`c`, bl`""`, bl`"t"`, bl`nil`][
      r(8)
    ]!
  } else {
    const members = Array.from({ length: r(3) }, () => small(r, depth + 1))
    switch (r(3)) {
      case 0:
        v = value.list(members)
        break
      case 1:
        v = value.record([
          r(2) === 0 ? small(r, 3) : [bl`p`, bl`q`][r(1)]!,
          ...members,
        ])
        break
      case 2:
        v = value.dict(members.map(m => [small(r, depth + 2), m]))
        break
      default:
        v = value.set(members)
    }
  }
  return r(9) === 0 ? withMark(v) : v
}

/** `part` with holes, some repeated, and the wild in place of some of its parts, anywhere: keys, members and heads too. */
function punch(r: Rand, part: Value, holes: Value[], depth = 0): Value {
  if (depth > 0 && r(3) === 0) {
    if (r(4) === 0) return bl`_`
    const hole = value.sym(
      ['x', 'y', 'z'][r(2)]!,
      r(5) === 0 ? !part.mark : part.mark
    )
    holes.push(hole)
    return hole
  }
  const p = (x: Value) => punch(r, x, holes, depth + 1)
  switch (part.kind) {
    case 'list':
      return value.list(part.items.map(p), part.mark)
    case 'record':
      return value.record(part.items.map(p), part.mark)
    case 'dict':
      return value.dict(
        part.entries().map(([k, x]) => [p(k), p(x)]),
        part.mark
      )
    case 'set':
      return value.set(part.children().map(p), part.mark)
    default:
      return part
  }
}

describe('fillings against brute force', () => {
  it('fillings are exactly the bindings under which the value fits', () => {
    const r = rng(2026_10_03)
    let filled = 0
    let skipped = 0
    for (let n = 0; n < 400; n++) {
      const v = small(r)
      const holes: Value[] = []
      const example = punch(r, v, holes)
      if (r(14) === 0) holes.push(bl`never`)
      const s = shape(example, holes, bl`_`)
      const brute = bruteForce(s, v)
      if (brute === undefined) {
        skipped++ // too many assignments to try them all
        continue
      }
      const answers = [...fillings(s, v)].map(hex)
      const found = new Set(answers)
      expect(found).toEqual(brute)
      expect(answers.length).toBe(found.size) // each once
      if (found.size > 0) filled++
    }
    expect(filled).toBeGreaterThan(100) // most cases have a filling to compare
    expect(skipped).toBeLessThan(20)
  })
})
