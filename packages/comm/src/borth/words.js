//@ts-check
/** @import {Value} from "@bassline/core/data" */
/** @import {BorthEvaluator} from "./evaluator.js" */
import { fresh, eq, isData } from '@bassline/core/data'
import { BorthError, truthy, asNum, toFloat } from './evaluator.js'

const KINDS = /** @type {const} */ ([
  'nil',
  'bool',
  'int',
  'float',
  'string',
  'symbol',
  'bytes',
  'list',
  'dict',
  'record',
  'set',
])

/**
 * @param {Value} v
 */
function toItems(v) {
  switch (v.kind) {
    case 'list':
      return v.value
    case 'set':
      return [...v.value.values()]
    case 'dict':
      return [...v.asSeq()]
    default:
      throw new BorthError('not-a-seq', v)
  }
}

/**
 * @param {Value} v
 */
function lengthOf(v) {
  switch (v.kind) {
    case 'list':
      return v.value.length
    case 'set':
    case 'dict':
      return v.value.size
    case 'string':
      return [...v.value].length
    default:
      throw new BorthError('not-a-seq', v)
  }
}

/**
 * @param {Value} v
 */
function asDict(v) {
  if (v.kind !== 'dict') throw new BorthError('not-a-dict', v)
  return v
}

/** Numeric three-way comparison of two values (sign of a − b). */
/**
 *
 * @param {Value} a
 * @param {Value} b
 */
function cmpNum(a, b) {
  const x = asNum(a)
  const y = asNum(b)
  if (x.kind === 'int' && y.kind === 'int') {
    return x.value < y.value ? -1 : x.value > y.value ? 1 : 0
  }
  const fx = toFloat(x)
  const fy = toFloat(y)
  return fx < fy ? -1 : fx > fy ? 1 : 0
}

/**
 * Install the standard word set on an evaluator.
 * @param {BorthEvaluator} ev
 */
export function installStdlib(ev) {
  /**
   * @param {string} name
   * @param {(e: BorthEvaluator) => void} fn
   */
  function p(name, fn) {
    ev.prim(name, fn)
  }

  // --- stack shuffling -----------------------------------------------------
  p('dup', e => {
    const a = e.pop()
    e.push(a)
    e.push(a)
  })
  p('drop', e => e.pop())
  p('swap', e => {
    const b = e.pop()
    const a = e.pop()
    e.push(b)
    e.push(a)
  })
  p('over', e => {
    const b = e.pop()
    const a = e.pop()
    e.push(a)
    e.push(b)
    e.push(a)
  })
  p('rot', e => {
    const c = e.pop()
    const b = e.pop()
    const a = e.pop()
    e.push(b)
    e.push(c)
    e.push(a)
  })
  p('nip', e => {
    const b = e.pop()
    e.pop()
    e.push(b)
  })
  p('2dup', e => {
    const b = e.pop()
    const a = e.pop()
    e.push(a)
    e.push(b)
    e.push(a)
    e.push(b)
  })
  p('dupd', e => {
    const b = e.pop()
    const a = e.pop()
    e.push(a)
    e.push(a)
    e.push(b)
  })

  // arithmetic
  p('+', e =>
    e.binop(
      (a, b) => a + b,
      (a, b) => a + b
    )
  )
  p('-', e =>
    e.binop(
      (a, b) => a - b,
      (a, b) => a - b
    )
  )
  p('*', e =>
    e.binop(
      (a, b) => a * b,
      (a, b) => a * b
    )
  )
  p('/', e =>
    e.binop(
      (a, b) => {
        if (b === 0n) throw new BorthError('division-by-zero')
        return a / b
      },
      (a, b) => a / b
    )
  )
  p('mod', e =>
    e.binop(
      (a, b) => {
        if (b === 0n) throw new BorthError('division-by-zero')
        return a % b
      },
      (a, b) => a % b
    )
  )
  p('neg', e => {
    const a = asNum(e.pop())
    e.push(a.kind === 'int' ? fresh.int(-a.value) : fresh.float(-a.value))
  })
  p('abs', e => {
    const a = asNum(e.pop())
    e.push(
      a.kind === 'int'
        ? fresh.int(a.value < 0n ? -a.value : a.value)
        : fresh.float(Math.abs(a.value))
    )
  })
  p('min', e => {
    const b = e.pop()
    const a = e.pop()
    e.push(cmpNum(a, b) <= 0 ? a : b)
  })
  p('max', e => {
    const b = e.pop()
    const a = e.pop()
    e.push(cmpNum(a, b) >= 0 ? a : b)
  })

  // comparison & boolean logic
  // equality is structural equality
  p('=', e => {
    const b = e.pop()
    const a = e.pop()
    e.push(fresh.bool(eq(a, b)))
  })
  p('!=', e => {
    const b = e.pop()
    const a = e.pop()
    e.push(fresh.bool(!eq(a, b)))
  })
  // ordering is numeric
  p('lt', e => e.ord(r => r < 0))
  p('gt', e => e.ord(r => r > 0))
  p('le', e => e.ord(r => r <= 0))
  p('ge', e => e.ord(r => r >= 0))
  p('not', e => e.push(fresh.bool(!truthy(e.pop()))))
  p('and', e => {
    const b = e.pop()
    const a = e.pop()
    e.push(fresh.bool(truthy(a) && truthy(b)))
  })
  p('or', e => {
    const b = e.pop()
    const a = e.pop()
    e.push(fresh.bool(truthy(a) || truthy(b)))
  })

  // combinators
  p('call', e => e.docol(e.popQuote()))
  p('dip', e => {
    const q = e.popQuote()
    const x = e.pop()
    e.docol(q)
    e.push(x)
  })
  p('if', e => {
    const elseQ = e.popQuote()
    const thenQ = e.popQuote()
    const cond = e.pop()
    e.docol(truthy(cond) ? thenQ : elseQ)
  })
  p('keep', e => {
    const q = e.popQuote()
    const x = e.pop()
    e.push(x)
    e.docol(q)
    e.push(x)
  })
  p('times', e => {
    const q = e.popQuote()
    const n = e.pop()
    if (n.kind !== 'int') throw new BorthError('not-an-int', n)
    for (let i = 0n; i < n.value; i++) e.docol(q)
  })

  // collection combinators
  p('each', e => {
    const q = e.popQuote()
    for (const it of toItems(e.pop())) {
      e.push(it)
      e.docol(q)
    }
  })
  p('map', e => {
    const q = e.popQuote()
    const out = []
    for (const it of toItems(e.pop())) {
      e.push(it)
      e.docol(q)
      out.push(e.pop())
    }
    e.push(fresh.list(out))
  })
  p('filter', e => {
    const q = e.popQuote()
    const out = []
    for (const it of toItems(e.pop())) {
      e.push(it)
      e.docol(q)
      if (truthy(e.pop())) out.push(it)
    }
    e.push(fresh.list(out))
  })
  p('fold', e => {
    const q = e.popQuote()
    let acc = e.pop()
    const items = toItems(e.pop())
    for (const it of items) {
      e.push(acc)
      e.push(it)
      e.docol(q)
      acc = e.pop()
    }
    e.push(acc)
  })
  p('length', e => e.push(fresh.int(BigInt(lengthOf(e.pop())))))
  p('empty?', e => e.push(fresh.bool(lengthOf(e.pop()) === 0)))

  // predicates
  p('kind', e => e.push(fresh.symbol(e.pop().kind)))
  for (const k of KINDS) {
    p(`${k}?`, e => e.push(fresh.bool(e.pop().kind === k)))
  }
  p('number?', e => {
    const v = e.pop()
    e.push(fresh.bool(v.kind === 'int' || v.kind === 'float'))
  })
  p('data?', e => e.push(fresh.bool(isData(e.pop()))))
  p('marked?', e => e.push(fresh.bool(e.pop().actionable)))
  p('mark', e => e.push(e.pop().copy(true)))
  p('unmark', e => e.push(e.pop().copy(false)))

  // sequence access
  p('at', e => {
    const i = e.pop()
    const seq = e.pop()
    if (i.kind !== 'int') throw new BorthError('not-an-int', i)
    e.push(toItems(seq).at(Number(i.value)) ?? fresh.nil())
  })
  p('first', e => e.push(toItems(e.pop()).at(0) ?? fresh.nil()))
  p('last', e => e.push(toItems(e.pop()).at(-1) ?? fresh.nil()))
  p('rest', e => e.push(fresh.list(toItems(e.pop()).slice(1))))
  p('push', e => {
    const x = e.pop()
    const seq = e.pop()
    if (seq.kind === 'list') e.push(fresh.list([...seq.value, x]))
    else if (seq.kind === 'set') e.push(seq.append(x))
    else throw new BorthError('not-a-seq', seq)
  })
  p('concat', e => {
    const b = e.pop()
    const a = e.pop()
    if (a.kind === 'list' || a.kind === 'set') e.push(a.append(b))
    else throw new BorthError('not-a-seq', a)
  })
  p('as-list', e => e.push(fresh.list(toItems(e.pop()))))

  // records
  p('head', e => {
    const r = e.pop()
    if (r.kind !== 'record') throw new BorthError('not-a-record', r)
    e.push(r.head)
  })
  p('fields', e => {
    const r = e.pop()
    if (r.kind !== 'record') throw new BorthError('not-a-record', r)
    e.push(fresh.list(r.fields))
  })
  p('record', e => {
    const fields = e.pop()
    const head = e.pop()
    if (fields.kind !== 'list') throw new BorthError('not-a-list', fields)
    e.push(fresh.record([head, ...fields.value]))
  })

  // dicts & sets
  p('get', e => {
    const key = e.pop()
    const d = asDict(e.pop())
    e.push(d.get(key) ?? fresh.nil())
  })
  p('assoc', e => {
    const val = e.pop()
    const key = e.pop()
    const d = asDict(e.pop())
    e.push(d.set(key, val))
  })
  p('keys', e => e.push(asDict(e.pop()).keys))
  p('values', e => e.push(asDict(e.pop()).values))
  p('has', e => {
    const key = e.pop()
    const c = e.pop()
    if (c.kind === 'dict' || c.kind === 'set') e.push(fresh.bool(c.has(key)))
    else throw new BorthError('not-a-collection', c)
  })
  p('dict', e => {
    const pairs = e.pop()
    if (pairs.kind !== 'list') throw new BorthError('not-a-list', pairs)
    /** @type {[Value, Value][]} */
    const entries = pairs.value.map(pr => {
      if (pr.kind !== 'list' || pr.value.length !== 2)
        throw new BorthError('not-a-pair', pr)
      return [pr.value[0], pr.value[1]]
    })
    e.push(fresh.dict(entries))
  })
  p('set', e => {
    const list = e.pop()
    if (list.kind !== 'list') throw new BorthError('not-a-list', list)
    e.push(fresh.set(list.value))
  })

  // --- atoms (light) -------------------------------------------------------
  p('str-concat', e => {
    const b = e.pop()
    const a = e.pop()
    if (a.kind !== 'string' || b.kind !== 'string')
      throw new BorthError('not-a-string', a.kind === 'string' ? b : a)
    e.push(fresh.string(a.value + b.value))
  })
  p('as-string', e => {
    const v = e.pop()
    if (v.kind === 'string') e.push(v)
    else if (v.kind === 'symbol') e.push(fresh.string(v.value))
    else throw new BorthError('not-stringable', v)
  })
  p('as-symbol', e => {
    const v = e.pop()
    if (v.kind === 'symbol') e.push(v)
    else if (v.kind === 'string') e.push(fresh.symbol(v.value))
    else throw new BorthError('not-symbolable', v)
  })
}
