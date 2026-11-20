/** @import { Value } from '../src/value/value.js' */
import { describe, it, expect } from 'vitest'
import { eq, int, list, symbol } from '../src/data.js'
import { rewrite, rules } from '../src/lang/rewrite.js'
import { read } from '../src/text/reader.js'

const v1 = src => read(src)[0]

/**
 * @param {(s: string) => boolean} matches
 * @param {(v: Value) => Value} fn
 */
function onSymbol(matches, fn) {
  /** @param {Value} v */
  return v => (v.kind === 'symbol' && matches(v.value) ? fn(v) : v)
}

/**
 * @param {string} headName
 * @param {(v: Value) => Value} fn
 */
function onHead(headName, fn) {
  /** @param {Value} v */
  return v =>
    v.kind === 'record' && v.head.kind === 'symbol' && v.head.value === headName
      ? fn(v)
      : v
}

describe('rewrite', () => {
  it('the identity rule is a no-op', () => {
    const v = v1('[1 (p 2 3) {a: 1}]')
    const rewritten = rewrite(v, x => x)
    expect(eq(rewritten, v)).toBe(true)
  })

  it('renames symbols by predicate, anywhere in the tree', () => {
    const ren = onSymbol(
      s => s.startsWith('foo-'),
      s => symbol('bar-' + s.value.slice(4))
    )
    const v = v1('[foo-a (foo-head foo-b 1) {foo-k: foo-v}]')
    const want = v1('[bar-a (bar-head bar-b 1) {bar-k: bar-v}]')
    expect(eq(rewrite(v, ren), want)).toBe(true)
  })

  it('expands a record head structurally', () => {
    const expand = onHead('def', r => list([...r.items]))
    expect(eq(rewrite(v1('(def foo 123)'), expand), v1('[def foo 123]'))).toBe(
      true
    )
  })

  it('reduces nested redexes to a fixpoint', () => {
    const succ = onHead('succ', r => int(Number(r.items[1].value) + 1))
    expect(eq(rewrite(v1('(succ (succ (succ 0)))'), succ), int(3n))).toBe(true)
  })

  it('fixpoint:false applies a rule once per node; fixpoint chases new redexes', () => {
    const r = rules(
      onHead('a', () => v1('(b)')), // (a) -> (b)
      onHead('b', () => v1('done')) // (b) -> done
    )
    expect(eq(rewrite(v1('(a)'), r, { fixpoint: false }), v1('(b)'))).toBe(true)
    expect(eq(rewrite(v1('(a)'), r), v1('done'))).toBe(true)
  })

  it('rules() takes the first rule that changes the node', () => {
    const r = rules(
      onHead('keep', x => x), // declines (returns unchanged)
      onSymbol(
        () => true,
        () => symbol('X')
      ) // renames any symbol
    )
    expect(eq(rewrite(v1('foo'), r), symbol('X'))).toBe(true)
  })
})
