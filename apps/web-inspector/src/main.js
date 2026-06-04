import { Bassline, comms } from '@bassline/std'
import { installGraph } from './graph.js'
import { cy } from './shared.js'

const bl = new Bassline().use(comms)
const inspect = installGraph(bl, cy)

inspect.seed = () => seed(bl, inspect)

globalThis.bl = bl
globalThis.cy = cy
globalThis.inspect = inspect

seed(bl, inspect)

function seed(bl, inspect) {
  const { verb, msg, noun, word } = bl
  const { propagator, port } = bl.fns
  cy.batch(() => {
    const ack = verb(m => {
      console.log('ack', m)
    })
    const nested = msg({
      label: bl.noun('nested message'),
      ack,
    })
    const entry = word({
      noun: nested,
      verb: m => {
        console.log('entry word heard', m)
      },
    })
    const root = msg({
      title: noun('runtime seed'),
      entry,
      count: noun(3),
    })

    const inbox = port(8)
    const outbox = propagator((incoming, send) => {
      console.log('propagating', incoming)
      send(incoming)
    })
    const sink = verb(m => {
      console.log('sink', m)
    })

    outbox.target(sink)

    bl.keep('root-message', root)
    bl.keep('nested-message', nested)
    bl.keep('entry-word', entry)
    bl.keep('inbox', inbox)
    bl.keep('inbox-word', inbox.toWord())
    bl.keep('outbox', outbox)
    bl.keep('outbox-word', outbox.toWord())
    bl.keep('sink-word', sink)
  })
  inspect.refresh()
}
