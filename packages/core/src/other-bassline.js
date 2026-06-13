import {
  assert,
  is,
  caseLambda,
  cond,
  multi,
  panic,
  HANDLE,
} from './other-utils.js'

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
    assert(ctx.words.has(id), `No such word: ${String(id)}`)
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

export function encodeJSON(form) {
  return JSON.stringify(encodeForm(form))
}

export const encodeForm = multi((...args) => {
  console.error(args)
  panic(`Unknown form`)
})

encodeForm.method(is('spelled-handle'), h => ({
  '@word': true,
  ctx: h.context.id,
  spelling: h.spelling,
  noun: h(),
  verb: h.hasVerb,
}))
encodeForm.method(is('id-handle'), h => ({
  '@word': true,
  ctx: h.context.id,
  id: h.id,
  noun: h(),
  verb: h.hasVerb,
}))
encodeForm.method(is('scalar'), v => v)
encodeForm.method(is('arr'), anArr => anArr.map(v => encodeForm(v)))
encodeForm.method(is('object'), obj =>
  Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, encodeForm(v)]))
)

function validatePacket(packet) {
  assert(is('object'), 'packet: must be an object')
  assert(
    packet.syntax === 'json',
    `packet: unsupported syntax "${packet.syntax}"`
  )
  assert(is('object'), 'packet: "parse" must be a plain object')
  const hasSpelled = packet.spelled != null
  const hasId = packet.id != null
  assert(
    hasSpelled !== hasId,
    'packet: exactly one of "spelled" or "id" must be present'
  )
}

export function interpretForm(form, contexts, routeBack) {
  if (typeof form !== 'object' || form === null) return localCtx.word(form)

  if (form['@word'] === true) {
    const { ctx, spelled, id, noun, verb } = form
    assert(ctx != null, '@word: missing "ctx"')
    assert(ctx in contexts, `@word: unknown ctx alias "${ctx}"`)

    if (ctx === localAlias) {
      if (spelled != null) {
        assert(
          localCtx.spellings.has(spelled),
          `@word: spelling "${spelled}" not found in local context "${ctx}"`
        )
        return localCtx.spelled(spelled)
      }
      if (id != null) {
        assert(
          localCtx.words.has(id),
          `@word: id "${id}" not found in local context "${ctx}"`
        )
        return localCtx.byId(id)
      }
      assert(false, '@word: local ref needs "spelled" or "id"')
    } else {
      assert(
        'noun' in form,
        `@word: remote word in ctx "${ctx}" must include "noun"`
      )
      if (verb) {
        assert(id != null, '@word: verb:true requires "id" as endpoint')
        return localCtx.word(noun ?? null, msg => routeBack(id, msg))
      }
      return localCtx.word(noun ?? null)
    }
  }

  return localCtx.word(form)
}

export function createParser(localCtx, routeBack = () => {}) {
  return function parse(packet) {
    validatePacket(packet)
    const { parse: form, spelled, id } = packet

    const message = {}
    for (const [key, form] of Object.entries(forms)) {
      message[key] = interpretForm(
        form,
        localCtx,
        contexts,
        localAlias,
        routeBack
      )
    }

    let handle
    if (spelled != null) {
      assert(
        localCtx.spellings.has(spelled),
        `packet: spelled continuation "${spelled}" not found in local context`
      )
      handle = localCtx.spelled(spelled)
    } else {
      assert(
        localCtx.words.has(targetId),
        `packet: id continuation "${targetId}" not found in local context`
      )
      handle = localCtx.byId(targetId)
    }

    handle(message)
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

console.log(encodeForm(aMsg))
