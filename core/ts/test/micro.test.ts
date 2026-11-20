import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { encode, readValue, value } from '../src/index.ts'
import {
  asValue,
  at,
  atFlat,
  BasslineError,
  bytes,
  ce,
  cmp,
  cmpBytes,
  del,
  dict,
  eq,
  excl,
  frame,
  get,
  has,
  incl,
  isPure,
  len,
  list,
  Live,
  marked,
  nil,
  nth,
  num,
  put,
  Reader,
  readAll,
  readOne,
  rec,
  reify,
  rewrite,
  set,
  setAt,
  setFlat,
  sym,
  text,
  write,
  ByteWriter,
  type Node,
  type Value,
} from '../src/micro.ts'

const blb = new Uint8Array(
  readFileSync(new URL('../../../corpus/corpus.blb', import.meta.url))
)
const cases = readAll(blb)

const byHead = (head: string) =>
  cases.filter(c => eq(at(c, 0), sym(head))).map(c => asValue(c))
const name = (c: Value) => {
  const n = asValue(at(c, 1))
  return n.kind === 'symbol' ? n.str : 'unnamed'
}
const payload = (c: Value, i: number) => {
  const b = asValue(at(c, i))
  if (b.kind !== 'bytes') throw new Error('not bytes')
  return b.bytes
}

function land(src: Uint8Array, step = src.length || 1) {
  const r = new Reader()
  const values: Value[] = []
  let refused = false
  try {
    for (let i = 0; i < src.length; i += step) {
      values.push(...r.read(src.subarray(i, i + step)))
    }
  } catch (e) {
    expect(e).toBeInstanceOf(BasslineError)
    refused = true
  }
  return { values, refused, starved: r.starved }
}

const m = (s: string) => readOne(encode(readValue(value, s)))

class Var extends Live {
  holds: Node
  asked = 0
  constructor(holds: Node) {
    super()
    this.holds = holds
  }
  override reified(): Value {
    this.asked++
    return rec([sym('var'), this.holds])
  }
}

describe('corpus', () => {
  it('reads corpus.blb and writes it back byte for byte', () => {
    expect(cases.length).toBeGreaterThan(100)
    const out = new ByteWriter()
    for (const c of cases) write(c, out)
    expect(out.take()).toEqual(blb)
  })

  for (const c of byHead('ce')) {
    it('ce ' + name(c), () => {
      const v = asValue(at(c, 2))
      const want = payload(c, 3)
      expect(ce(v)).toEqual(want)
      for (const step of [want.length, 1]) {
        const l = land(want, step)
        expect(l.refused).toBe(false)
        expect(l.starved).toBe(false)
        expect(l.values.length).toBe(1)
        expect(eq(l.values[0]!, v)).toBe(true)
      }
    })
  }

  for (const c of byHead('reject')) {
    it('reject ' + name(c), () => {
      expect(land(payload(c, 2)).refused).toBe(true)
      expect(land(payload(c, 2), 1).refused).toBe(true)
    })
  }

  for (const c of byHead('starved')) {
    it('starved ' + name(c), () => {
      for (const step of [undefined, 1]) {
        const l = land(payload(c, 2), step)
        expect(l.refused).toBe(false)
        expect(l.values.length).toBe(0)
        expect(l.starved).toBe(true)
      }
    })
  }

  it('orders as CE bytes do', () => {
    const values = byHead('ce').map(c => asValue(at(c, 2)))
    for (const a of values) {
      for (const b of values) {
        expect(Math.sign(cmp(a, b))).toBe(Math.sign(cmpBytes(ce(a), ce(b))))
      }
    }
  })
})

describe('lives', () => {
  it('a live is after every value, and equal only to itself', () => {
    const a = new Live()
    const b = new Live()
    expect(cmp(num(0), a)).toBeLessThan(0)
    expect(cmp(a, num(0))).toBeGreaterThan(0)
    expect(eq(a, a)).toBe(true)
    expect(cmp(a, b)).toBeLessThan(0)
    expect(cmp(b, a)).toBeGreaterThan(0)
  })

  it('a bare live refuses to say what it is', () => {
    expect(() => reify(new Live())).toThrow(BasslineError)
    expect(() => ce(list([new Live()]))).toThrow(BasslineError)
  })

  it('reify asks each live once, deep until nothing live is left', () => {
    const inner = new Var(num(1))
    const outer = new Var(inner)
    const tree = list([outer, sym('x')])
    expect(isPure(tree)).toBe(false)

    const once = reify(tree)
    expect([outer.asked, inner.asked]).toEqual([1, 0])
    expect(isPure(once)).toBe(false)
    expect(at(asValue(at(once, 0)), 1)).toBe(inner)

    const whole = reify(tree, true)
    expect(isPure(whole)).toBe(true)
    expect(eq(whole, m('[(var (var 1)) x]'))).toBe(true)
    expect(at(tree, 0)).toBe(outer)
  })

  it('reify hands back the value itself when nothing in it is live', () => {
    const v = m('[a {b: [c]} {d e}]')
    expect(reify(v, true)).toBe(v)
  })

  it('a set is put back in order when its members are reified', () => {
    const tree = set([new Var(sym('b')), new Var(sym('a')), sym('z')])
    expect(eq(nth(tree, 0), sym('z'))).toBe(true)
    expect(eq(reify(tree), m('{(var a) (var b) z}'))).toBe(true)
  })

  it('members that reify alike are refused', () => {
    expect(() => reify(set([new Var(nil()), new Var(nil())]))).toThrow(
      BasslineError
    )
    const keys = dict([
      [new Var(nil()), num(1)],
      [new Var(nil()), num(2)],
    ])
    expect(() => reify(keys)).toThrow(BasslineError)
  })

  it('round trips once reified', () => {
    const tree = dict([[sym('k'), new Var(text('v'))]])
    expect(eq(readOne(ce(reify(tree))), m('{k: (var "v")}'))).toBe(true)
  })

  it('rewrite binds lives in place of values and leaves the original', () => {
    const v = m('[x! (y x!) {x!: 1}]')
    const bound = new Var(num(7))
    const out = rewrite(
      v,
      n => n.kind === 'symbol' && n.mark,
      () => bound
    )
    expect(eq(v, m('[x! (y x!) {x!: 1}]'))).toBe(true)
    expect(eq(reify(out), m('[(var 7) (y (var 7)) {(var 7): 1}]'))).toBe(true)
    expect(
      rewrite(
        v,
        () => false,
        n => n
      )
    ).toBe(v)
  })
})

describe('values', () => {
  it('constructors refuse what is not a value', () => {
    expect(() => num(1.5)).toThrow(BasslineError)
    expect(() => num('01')).toThrow(BasslineError)
    expect(() => text('\ud800')).toThrow(BasslineError)
    expect(() => rec([])).toThrow(BasslineError)
    expect(() => frame('set', [sym('a'), sym('a')])).toThrow(BasslineError)
    expect(() => frame('set', [sym('b'), sym('a')])).toThrow(BasslineError)
    expect(() => frame('dict', [sym('a')])).toThrow(BasslineError)
  })

  it('sugar sorts, and reads as the text does', () => {
    expect(eq(set([sym('b'), sym('a'), sym('b')]), m('{a b}'))).toBe(true)
    const d = dict([
      [sym('b'), num(2)],
      [sym('a'), num(1)],
      [sym('b'), num(3)],
    ])
    expect(eq(d, m('{a: 1 b: 3}'))).toBe(true)
    expect(eq(num(2n ** 80n), m('1208925819614629174706176'))).toBe(true)
    expect(eq(marked(bytes(Uint8Array.of(1, 2))), m('0x0102!'))).toBe(true)
    expect(
      eq(frame('dict', [sym('a'), num(1), sym('b'), num(2)]), m('{a: 1 b: 2}'))
    ).toBe(true)
  })

  it('edits make new values', () => {
    const d = m('{a: 1 b: 2}')
    expect(eq(put(d, sym('c'), num(3)), m('{a: 1 b: 2 c: 3}'))).toBe(true)
    expect(eq(put(d, sym('a'), num(9)), m('{a: 9 b: 2}'))).toBe(true)
    expect(eq(del(d, sym('a')), m('{b: 2}'))).toBe(true)
    expect(eq(get(d, sym('b'))!, num(2))).toBe(true)
    expect(get(d, sym('z'))).toBeUndefined()
    expect(eq(d, m('{a: 1 b: 2}'))).toBe(true)

    const s = m('{a c}')
    expect(eq(incl(s, sym('b')), m('{a b c}'))).toBe(true)
    expect(incl(s, sym('a'))).toBe(s)
    expect(eq(excl(s, sym('a')), m('{c}'))).toBe(true)
    expect(has(s, sym('c'))).toBe(true)
    expect(has(d, sym('c'))).toBe(false)

    const l = m('[a b]')
    expect(eq(setAt(l, 1, sym('z')), m('[a z]'))).toBe(true)
    expect(() => setAt(l, 2, sym('z'))).toThrow(BasslineError)
    expect(len(d)).toBe(4)
    expect(eq(nth(d, 3), num(2))).toBe(true)
  })
})

describe('flat positions', () => {
  it('preorder counts frames, record heads, dict keys and values', () => {
    const root = m('(a [b c] (d e [f g {h: i {j}: k}]))')
    const expected = [
      '(a [b c] (d e [f g {h: i {j}: k}]))',
      'a',
      '[b c]',
      'b',
      'c',
      '(d e [f g {h: i {j}: k}])',
      'd',
      'e',
      '[f g {h: i {j}: k}]',
      'f',
      'g',
      '{h: i {j}: k}',
      'h',
      'i',
      '{j}',
      'j',
      'k',
    ]
    expected.forEach((s, i) => expect(eq(atFlat(root, i), m(s))).toBe(true))
    expect(atFlat(root, 0)).toBe(root)
    expect(() => atFlat(root, expected.length)).toThrow(BasslineError)
    expect(() => atFlat(root, -1)).toThrow(BasslineError)
  })

  it('a live and an empty frame each hold one position', () => {
    const live = new Live()
    const root = list([list(), set(), dict(), live, sym('last', true)])
    for (let i = 0; i < 5; i++) expect(atFlat(root, i + 1)).toBe(at(root, i))
    expect(() => atFlat(root, 6)).toThrow(BasslineError)
    expect(() => atFlat(live, 1)).toThrow(BasslineError)
  })

  it('replaces the root, a frame, a record head and a nested atom', () => {
    let root: Node = m('(a [b c] (d e))')
    root = setFlat(root, 1, sym('head', true))
    expect(eq(root, m('(head! [b c] (d e))'))).toBe(true)
    root = setFlat(root, 4, sym('last'))
    expect(eq(root, m('(head! [b last] (d e))'))).toBe(true)
    root = setFlat(root, 2, list())
    expect(eq(root, m('(head! [] (d e))'))).toBe(true)
    expect(eq(setFlat(root, 0, sym('root')), sym('root'))).toBe(true)
  })

  it('puts sets and dict keys back in order', () => {
    expect(eq(setFlat(m('{a b}'), 1, sym('z')), m('{b z}'))).toBe(true)
    expect(eq(setFlat(m('{[a] [b]}'), 2, sym('z')), m('{[b] [z]}'))).toBe(true)
    expect(eq(setFlat(m('{a: 1 b: 2}'), 1, sym('z')), m('{b: 2 z: 1}'))).toBe(
      true
    )
    expect(
      eq(setFlat(m('{[a]: 1 [b]: 2}'), 2, sym('z')), m('{[b]: 2 [z]: 1}'))
    ).toBe(true)
    expect(
      eq(setFlat(m('{{k: a} {k: b}}'), 3, sym('z')), m('{{k: b} {k: z}}'))
    ).toBe(true)
    expect(
      eq(setFlat(m('{{a b} {b c}}'), 2, sym('z')), m('{{b c} {b z}}'))
    ).toBe(true)
  })

  it('a repeat is refused and the original stands', () => {
    for (const [s, i] of [
      ['{a b}', 1],
      ['{[a] [b]}', 2],
      ['{a: 1 b: 2}', 1],
      ['{[a]: 1 [b]: 2}', 2],
    ] as const) {
      const original = m(s)
      expect(() => setFlat(original, i, sym('b'))).toThrow(BasslineError)
      expect(eq(original, m(s))).toBe(true)
    }
    expect(() => setFlat(m('{{a b} {b c}}'), 2, sym('c'))).toThrow(
      BasslineError
    )
  })

  it('a live can be replaced and put, but not entered', () => {
    const live = new Live()
    let root: Node = list([live, list(), sym('end')])
    root = setFlat(root, 1, sym('plain'))
    root = setFlat(root, 2, live)
    expect(eq(root, list([sym('plain'), live, sym('end')]))).toBe(true)
    for (const i of [-1, 4, Number.MAX_SAFE_INTEGER]) {
      expect(() => setFlat(root, i, sym('no'))).toThrow(BasslineError)
    }
    for (const leaf of [live, list(), sym('atom')]) {
      expect(() => setFlat(leaf, 1, sym('no'))).toThrow(BasslineError)
    }
  })
})
