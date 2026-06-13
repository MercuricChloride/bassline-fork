/**
 * @import { Msg, Send, WithCaps } from "@bassline/core"
 */
// import { msg, is, failure } from '@bassline/core'

export default function (bl) {
  const { is, msg, word, filter, propagator } = bl.reference

  function call(aMsg, ...args) {
    const { call } = aMsg
    if (!is.vbound(call)) {
      throw new Error(`cannot call ${String(aMsg)}`)
    }
    return new Promise((resolve, reject) => {
      const req = msg({
        args,
        resolve,
        reject,
      })
      call.verb(req)
    })
  }

  function formatResult(v) {
    if (is.msg(v)) return v
    if (is.undefined(v)) return msg({})
    if (is.fn(v)) return lambda(v)
    throw new TypeError(`Invalid result: ${String(v)}`)
  }

  function lambda(fn) {
    const arity = fn.length
    const validCall = filter(aMsg => {
      const { resolve, reject, args } = aMsg
      return (
        [resolve, reject].every(is.vbound) &&
        is.nbound(args) &&
        is.array(args.noun)
      )
    })
    const doCall = propagator(async aMsg => {
      const { resolve, reject, args } = aMsg
      try {
        const result = await fn(...args.noun)
        return resolve.verb(formatResult(result))
      } catch (e) {
        if (e instanceof Error) {
          return reject.verb(msg({ error: e.message }))
        }
        console.warn('unhandled something? ', e)
      }
    })

    validCall.target(doCall.asWord())

    const entry = word(arity, aMsg => {
      validCall.send(aMsg)
    })

    return msg({
      call: entry,
      arity,
    })
  }

  return { lambda, call, validCall }
}

// const description = `\
// I am a lambda.
// I am internally a curried function.
// I do not auto curry, so please invoke me 1 arg at a time. :)
// I will only accept messages with the caps: resolve + reject.
// When you invoke my call cap, I will apply my function to the message
// and invoke resolve or reject.

// I will always resolve & reject a message with caps.
// If the fn returns a function, it will resolve to another lambda msg.
// If the fn returns a msg, it will resolve to the msg.
// If the fn returns undefined, it will resolve an empty message.
// Anything else will reject the message.`

// /**
//  * @typedef {WithCaps<{ call: Send }>} LambdaMsg
//  */

// /**
//  * Wraps a function as a Msg with a `call` cap. Invoking `call` with a Msg that
//  * carries `resolve`/`reject` caps applies `fn` and routes the result.
//  * @param {(m: Msg) => unknown} fn
//  * @param {Msg} [target]
//  * @returns {LambdaMsg}
//  */
// export function lambda(fn, target = msg()) {
//   return target.defaults({ description }).grantCaps({ call })

//   /** @param {Msg} aMsg */
//   async function call(aMsg) {
//     if (!aMsg.capableOf(['resolve', 'reject'])) return
//     // we do this to copy the resolve & reject caps for santiary reasons
//     const responder = aMsg.copy()
//     let transferred = false
//     try {
//       const result = await fn(aMsg)
//       if (is.msg(result)) {
//         return responder.invoke('resolve', result)
//       }
//       if (is.fn(result)) {
//         transferred = true
//         const m = lambda(/** @type {(m: Msg) => unknown} */ (result)).closedBy(
//           target
//         )
//         return responder.invoke('resolve', m)
//       }
//       if (is.undefined(result)) {
//         return responder.invoke('resolve', msg())
//       }
//       throw failure(`invalid result: ${JSON.stringify(result)}`)
//     } catch (e) {
//       if (e instanceof Error) {
//         return responder.invoke('reject', msg().merge({ error: e.message }))
//       }
//       throw e
//     } finally {
//       responder.close()
//       if (!transferred) aMsg.close()
//     }
//   }
// }

// /**
//  * Grants `resolve` and `reject` caps on aMsg and returns a Promise that
//  * settles when either is invoked.
//  * @param {Msg} aMsg
//  * @returns {Promise<Msg>}
//  */
// export function withResolver(aMsg) {
//   return new Promise((resolve, reject) => {
//     aMsg.grantCaps({ resolve, reject })
//   })
// }

// /**
//  * Builds a request helper for a given cap spelling.
//  * @param {string} spelling
//  * @returns {(target: Msg | Promise<Msg>, aMsg?: Msg) => Promise<Msg>}
//  */
// export const request =
//   spelling =>
//   async (aTarget, aMsg = msg()) => {
//     const promise = withResolver(aMsg)
//     const lam = await aTarget
//     lam.invoke(spelling, aMsg)
//     const result = await promise
//     return result
//   }

// export const call = request('call')
