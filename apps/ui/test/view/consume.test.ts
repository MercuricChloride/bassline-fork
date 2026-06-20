import { describe, expect, it } from 'vitest'
import { kind } from '@bassline/core/match'
import { read } from '@bassline/core/text'
import { collect } from '~/view/collect'
import { asString, asToken } from '~/view/collect'
import { resolve, resolveDeep, seed } from '~/view/bindings'
import { makeRx, recognize, type Recognizers } from '~/view/consume'
import { at, keyed, sk } from '~/view/match'

const store = seed(read('<doc `<def-custom x "X"> `<def-custom y "Y">>')[0])
const rx = makeRx(store)

describe('resolution depth', () => {
  it('flat resolve leaves nested refs alone; deep resolves them', () => {
    const v = read('{a: `x b: {c: `y}}')[0] // a dict holding refs `x and `y
    // flat: top-level is a dict, not a ref, so unchanged
    expect(resolve(v, store).eq(v)).toBe(true)
    // deep: every ref dereferenced through the tree
    const deep = resolveDeep(v, store)
    expect(asString(at(sk('a'))(deep))).toBe('X')
    const inner = at(sk('b'))(deep)
    expect(inner && asString(at(sk('c'))(inner))).toBe('Y')
  })
})

describe('recognize — fold a table over a directive stream', () => {
  type Cfg = { gap?: string; color?: string }
  const table: Recognizers<Cfg> = [
    [
      keyed(sk('gap')),
      (d, acc, r) => ({ ...acc, gap: asToken(r.flat(at(sk('gap'))(d))) }),
    ],
    [
      keyed(sk('color')),
      (d, acc, r) => ({ ...acc, color: asString(r.flat(at(sk('color'))(d))) }),
    ],
  ]

  it('recognizes config and resolves a ref value (flat)', () => {
    const { directives } = collect(read('<box `{gap: md} `{color: `x}>')[0])
    const cfg = recognize(directives, table, {}, rx)
    expect(cfg.gap).toBe('md')
    expect(cfg.color).toBe('X') // `x dereferenced
  })

  it('skips directives no rule matches', () => {
    const { directives } = collect(read('<box `{gap: sm} `{mystery: 1}>')[0])
    const cfg = recognize(directives, table, {}, rx)
    expect(cfg).toEqual({ gap: 'sm' })
  })

  it('fires EVERY matching rule for a multi-key directive dict', () => {
    const { directives } = collect(read('<box `{gap: lg color: `y}>')[0])
    const cfg = recognize(directives, table, {}, rx)
    expect(cfg).toEqual({ gap: 'lg', color: 'Y' }) // both keys handled from one dict
  })
})

describe("rx — depth is the consumer's choice", () => {
  it('raw leaves a ref unresolved; deep resolves inside a structure', () => {
    const refX = read('`x')[0]
    expect(rx.raw(refX)).toBe(refX) // deferred: untouched
    expect(kind.string(rx.flat(refX)!)).toBe(true) // resolved to "X"
    const program = read('`<set a `x>')[0] // an actionable record (a handler)
    expect(rx.raw(program)).toBe(program) // deferred whole
    // deep would dereference the inner `x even inside the record:
    const deep = rx.deep(program)!
    expect(kind.record(deep)).toBe(true)
  })
})
