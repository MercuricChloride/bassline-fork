import { msg, is, failure } from '@bassline/core'
import { lambda, call } from '../src/lambda.js'

async function evaluate(anExpr) {
  const expr = await anExpr
  if (is.msg(expr)) return expr
  if (!is.array(expr)) throw failure('evalute requires an array / msg for expr')
  const [head, ...tail] = expr
  let result = await evaluate(head)
  for (const m of tail) {
    result = await call(result, await evaluate(m))
  }
  return result
}

const k = lambda(x => _y => x).merge({
  description: 'I am the K combinator. K x y => x',
})

const s = lambda(
  x => y => async z =>
    evaluate([
      [x, z],
      [y, z],
    ])
).merge({ description: 'I am the S combinator' })

const i = (await evaluate([s, k, k])).merge({ description: '' })

let res = await evaluate([i, msg({ scalar: 5 })])
console.log(res)
res = await evaluate([i, msg({ scalar: 9 })])
console.log(res)
