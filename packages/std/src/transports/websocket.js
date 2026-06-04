// [[file:../../../../book.org::*WebSocket][WebSocket:1]]
import { verb, msg } from '@bassline/core'
import { Port } from '../comms.js'

//TODO: FIX PROPERLY!
export function fromWebSocket(ws) {
  const outgoing = verb(m => ws.write(m))
  const incoming = new Port()
  ws.addEventListener('message', e => {
    try {
      incoming.send(msg(JSON.parse(e.data)))
    } catch (e) {
      console.error('failed to parse: ', e)
    }
  })

  ws.addEventListener('close', incoming.close)
  ws.addEventListener('error', incoming.close)
  incoming.ctl.onClose(() => ws.close())

  return [incoming, outgoing]
}

// WebSocket:1 ends here
