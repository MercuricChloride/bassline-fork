import { describe, it, expect } from 'vitest'
import * as D from '../src/data.js'
import {
  children,
  rebuild,
  rewrite,
  rules,
  onHead,
  onSymbol,
} from '../src/lang/rewrite.js'
import { parse } from '../src/text/parser.js'

const v1 = src => parse(src)[0]

describe('children / rebuild', () => {
  it('lists the ordered constituents (dict flattened, record head-first)', () => {
    expect(children(D.list([D.int(1n), D.int(2n)]))).toHaveLength(2)
    expect(children(D.record(D.sym('p'), [D.int(1n)]))).toHaveLength(2) // head + field
    expect(children(D.dict([[D.sym('a'), D.int(1n)]]))).toHaveLength(2) // k, v flattened
    expect(children(D.set([D.int(1n), D.int(2n)]))).toHaveLength(2)
    expect(children(D.int(1n))).toEqual([]) // atom
  })

  it('rebuild inverts children', () => {
    for (const v of [
      D.list([D.int(1n), D.int(2n)]),
      D.record(D.sym('p'), [D.int(1n), D.int(2n)]),
      D.dict([
        [D.sym('a'), D.int(1n)],
        [D.sym('b'), D.int(2n)],
      ]),
      D.set([D.int(1n), D.int(2n)]),
      D.int(7n),
    ]) {
      expect(D.eq(rebuild(v, children(v)), v)).toBe(true)
    }
  })

  it('rebuild preserves the actionable bit', () => {
    const v = D.list([D.int(1n)]).toActionable()
    const r = rebuild(v, children(v))
    expect(D.isActionable(r)).toBe(true)
    expect(D.eq(r, v)).toBe(true)
  })
})

describe('rewrite', () => {
  it('the identity rule is a no-op', () => {
    const v = v1('[1 <p 2 3> {a: 1}]')
    expect(
      D.eq(
        rewrite(v, x => x),
        v
      )
    ).toBe(true)
  })

  it('renames symbols by predicate, anywhere in the tree', () => {
    const ren = onSymbol(
      s => s.startsWith('foo-'),
      s => D.sym('bar-' + s.value.slice(4))
    )
    const v = v1('[foo-a <foo-head foo-b 1> {foo-k: foo-v}]')
    const want = v1('[bar-a <bar-head bar-b 1> {bar-k: bar-v}]')
    expect(D.eq(rewrite(v, ren), want)).toBe(true)
  })

  it('expands a record head structurally', () => {
    const expand = onHead('def', r => D.list([r.head, ...r.fields]))
    expect(
      D.eq(rewrite(v1('<def foo 123>'), expand), v1('[def foo 123]'))
    ).toBe(true)
  })

  it('reduces nested redexes to a fixpoint', () => {
    const succ = onHead('succ', r => D.int(r.fields[0].value + 1n))
    expect(D.eq(rewrite(v1('<succ <succ <succ 0>>>'), succ), D.int(3n))).toBe(
      true
    )
  })

  it('fixpoint:false applies a rule once per node; fixpoint chases new redexes', () => {
    const r = rules(
      onHead('a', () => v1('<b>')), // <a> -> <b>
      onHead('b', () => v1('done')) // <b> -> done
    )
    expect(D.eq(rewrite(v1('<a>'), r, { fixpoint: false }), v1('<b>'))).toBe(
      true
    )
    expect(D.eq(rewrite(v1('<a>'), r), v1('done'))).toBe(true)
  })

  it('rules() takes the first rule that changes the node', () => {
    const r = rules(
      onHead('keep', x => x), // declines (returns unchanged)
      onSymbol(
        () => true,
        () => D.sym('X')
      ) // renames any symbol
    )
    expect(D.eq(rewrite(v1('foo'), r), D.sym('X'))).toBe(true)
  })
})
