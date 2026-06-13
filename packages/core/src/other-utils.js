export const HANDLE = Symbol.for('$$BASSLINE_HANDLE$$')

export const panic = msg => {
  throw new Error(msg)
}

export const assert = (valid, condition) => valid || panic(condition)

const condDefault = (...args) => panic(`cond: No dispatch case for [${args}]`)

export function cond(cases, fallback = condDefault) {
  return (...args) => {
    for (const [predicate, fn] of cases) {
      if (predicate(...args)) return fn(...args)
    }
    return fallback(...args)
  }
}

export function multi(fallback) {
  const data = {
    cases: [],
    fallback,
  }
  const mm = cond(data.cases, data.fallback)
  mm.fallback = fn => (data.fallback = fn)
  mm.method = (predicate, fn) => data.cases.push([predicate, fn])
  return mm
}

export function caseLambda(...fns) {
  return cond(fns.map(f => [(...args) => args.length === f.length, f]))
}

export const matcher = () => {
  const predicates = {}
  const def = (label, predicate) => {
    assert(typeof label === 'string', `Invalid label!`)
    assert(typeof predicate === 'function', `Invalid predicate!`)
    predicates[label] = predicate
    return inst
  }
  const inst = (label, ...args) => {
    if (args.length === 0) return (...args) => inst(label, ...args)
    return predicates[label](...args)
  }
  inst.def = def
  inst.predicates = predicates
  return inst
}

export const is = matcher()

is.def('null', v => v === null)
is.def('arr', v => Array.isArray(v))
is.def('number', v => typeof v === 'number')
is.def('string', v => typeof v === 'string')
is.def('boolean', v => typeof v === 'boolean')
is.def(
  'scalar',
  v => is('null', v) || ['string', 'number', 'boolean'].includes(typeof v)
)
is.def('object', v => typeof v === 'object' && !is('null', v) && !is('arr', v))
is.def('fn', v => typeof v === 'function')
is.def('handle', v => is('fn', v) && v[HANDLE])
is.def('spelled-handle', v => is('handle', v) && v.spelling)
is.def('id-handle', v => is('handle', v) && v.id)
is.def('msg', v => is('object', v) && Object.values(v).every(is('handle')))
