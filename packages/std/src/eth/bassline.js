import Core from '@bassline/core'
import comms from '../comms.js'
import fns from '../lambda.js'
import rt from '../rt.js'

const Bassline = Core.extend(rt)

const bassline = new Bassline().extend(comms).extend(fns)

const { lambda, msg, word } = bassline.reference

const doubler = lambda(n => msg({ result: n.noun * 2 }))

const result = await bassline.call(doubler, word(123))

doubler.call.verb(msg({ hello: 'world' }))

console.log(result)

console.log(bassline)

for (const m of bassline.messages) bassline.discard(m)

console.log(bassline)

export default bassline

bassline.call(doubler, word(123)).then(console.log)
