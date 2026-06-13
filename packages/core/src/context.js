// [[file:context.org::helperfns][helperfns]]
const nary =
  (f, g = f) =>
  (...args) =>
    args.length ? f(args) : g(args)
const apply = (f, a) => f.apply(null, a)

const cond = nary(cases => {
  for (const [bool, body] of cases) {
    if (bool) return body()
  }
})

const panic = (msg, ...args) => {
  console.error(msg, ...args)
  throw new Error(msg)
}

const assert = nary(assertions => {
  const conditions = assertions.map(([p, m]) => [!p, () => panic(m)])
  return apply(cond, conditions)
})

const caseLambda = nary(fns =>
  nary(args => {
    for (const f of fns) {
      if (f.length === 0 || args.length === f.length) return apply(f, args)
    }
    panic(`No fn for arity: ${args.length}`)
  })
)
// helperfns ends here

// [[file:context.org::is][is]]
const HANDLE = Symbol.for('$$BASSLINE_HANDLE$$')

const some = caseLambda(
  preds => v => some(preds, v),
  (preds, v) => preds.some(f => f(v))
)
const every = caseLambda(
  preds => v => every(preds, v),
  (preds, v) => preds.every(f => f(v))
)
const hasKeys = caseLambda(
  keys => v => hasKeys(keys, v),
  (keys, v) => keys.every(k => k in v)
)

const is = {
  scalar: v => some([is.null, is.string, is.number, is.boolean], v),
  handle: v => every([is.fn, hasKeys(HANDLE)], v),
  spelledHandle: v => every([is.handle, hasKeys('spelling')], v),
  idHandle: v => every([is.handle, hasKeys('id')], v),
  msg: v => is.object(v) && Object.values(v).every(is.handle),
}
// is ends here

// [[file:context.org::context][context]]
export function context() {
  const word = caseLambda(
    n => word(n, null),
    (n, v) => {
      const id = crypto.randomUUID()
      ctx.words.set(id, { id, noun: n, verb: v })
      return createHandle(() => id, { id })
    }
  )

  const spelled = spelling =>
    createHandle(() => ctx.spellings.get(spelling), { spelling })

  const byId = id => createHandle(() => id, { id })

  const ctx = {
    id: crypto.randomUUID(),
    words: new Map(),
    spellings: new Map(),
    entry,
    clear,
    word,
    spelled,
    byId,
    spell,
  }

  return ctx

  function clear() {
    ctx.words.clear()
    ctx.spellings.clear()
  }

  function spell(aWord, aSpelling) {
    entry(aWord.id)
    ctx.spellings.set(aSpelling, aWord.id)
    return aWord
  }

  function entry(id) {
    assert([ctx.words.has(id), `No such word: ${String(id)}`])
    return ctx.words.get(id)
  }

  function createHandle(getId, attributes = {}) {
    const handle = caseLambda(
      () => entry(getId()).noun,
      aMsg => {
        entry(getId()).verb(aMsg)
      }
    )
    Object.defineProperty(handle, 'hasVerb', {
      get: () => entry(getId()).verb != null,
    })
    Object.assign(handle, { ...attributes, context: ctx, [HANDLE]: true })
    return handle
  }
}

const foo = context()
const bar = context()

const a = foo.word(123, v => console.log(v))
const b = foo.word('hello')
const c = foo.spelled('something')
const d = foo.spell(b, 'something')
const e = bar.word(123)

const aMsg = { a, b, c, d, e }

console.log(aMsg)
// context ends here
