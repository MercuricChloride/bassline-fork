import { describe, it, expect } from 'vitest'
import * as D from '../src/data.js'
import { evaluator } from '../src/lang/eval.js'
import { parse } from '../src/text/parser.js'

const v1 = src => parse(src)[0]

// A tiny env calculator. `add` is applicative (evaluates its fields); `define`
// is vau (it does NOT evaluate its name); `quote` strips the actionable bit.
const handlers = {
  records: {
    add: (rec, ctx) => {
      let sum = 0n
      for (const f of rec.fields) sum += ctx.eval(f).value
      return D.int(sum)
    },
    define: (rec, ctx) => {
      const [name, expr] = rec.fields
      ctx.state.set(name.value, ctx.eval(expr))
      return D.nil()
    },
    quote: rec => rec.fields[0].toStatic(),
  },
}

describe('evaluator', () => {
  it('reduces an actionable call', () => {
    const ev = evaluator(handlers)
    expect(D.eq(ev.send(v1('`<add 1 2>')), D.int(3n))).toBe(true)
  })

  it('threads state across sends (define, then reference)', () => {
    const ev = evaluator(handlers)
    expect(D.eq(ev.send(v1('`<define x `<add 1 2>>')), D.nil())).toBe(true)
    // `x is a variable reference (actionable symbol); 10 is a literal
    expect(D.eq(ev.send(v1('`<add `x 10>')), D.int(13n))).toBe(true)
  })

  it('define does not evaluate its name (vau)', () => {
    const ev = evaluator(handlers)
    ev.send(v1('`<define y 5>'))
    expect(ev.state.has('y')).toBe(true)
    expect(D.eq(ev.state.get('y'), D.int(5n))).toBe(true)
  })

  it('eval of pure data is the identity', () => {
    const ev = evaluator(handlers)
    const data = v1('[1 <p 2> {a: 1}]')
    expect(D.eq(ev.send(data), data)).toBe(true)
  })

  it('splices an actionable subterm inside static data', () => {
    const ev = evaluator(handlers)
    expect(D.eq(ev.send(v1('[1 `<add 2 3> 4]')), v1('[1 5 4]'))).toBe(true)
  })

  it('quote strips the bit, so its content stays data', () => {
    const ev = evaluator(handlers)
    expect(D.eq(ev.send(v1('`<quote `<add 1 2>>')), v1('<add 1 2>'))).toBe(true)
  })

  it('a static symbol is a literal, not a reference', () => {
    const ev = evaluator(handlers)
    expect(D.eq(ev.send(v1('foo')), D.sym('foo'))).toBe(true)
  })

  it('throws on an unbound reference and on an unknown verb', () => {
    const ev = evaluator(handlers)
    expect(() => ev.send(v1('`z'))).toThrow()
    expect(() => ev.send(v1('`<bogus 1>'))).toThrow()
  })
})
