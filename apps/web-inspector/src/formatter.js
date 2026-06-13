import { is, msg, noun } from '@bassline/core'

const msgFormatter = {
  hasBody: is.msg,
  header: m => {
    if (!is.msg(m)) return null
    return [
      'div',
      { style: 'font-weight: bold; padding: .25rem;' },
      `Msg: ${m.entries.length}`,
    ]
  },
  body: m => [
    'ol',
    ...m.entries.map(([k, v]) => [
      'li',
      [`span`, `-${k}: `, JSON.stringify(v)],
    ]),
  ],
}

globalThis.devtoolsFormatters ??= []
globalThis.devtoolsFormatters.push(msgFormatter)

const aMsg = msg({ hello: noun(123) })

console.log(aMsg)
