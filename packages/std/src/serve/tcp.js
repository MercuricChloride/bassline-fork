// [[file:../../../../book.org::*Serving (TCP)][Serving (TCP):1]]
import nodeNet from 'node:net'
import { fromSocket } from '../transports/socket.js'
import defaultFrame from '../frame/jsonl.js'

export function serve(onConnect, options = {}, createFrame = defaultFrame) {
  const clients = new Set()
  const server = nodeNet.createServer(socket => {
    const [incoming, outgoing] = fromSocket(socket, createFrame)
    clients.add(incoming)
    incoming.ctl.onClose(() => clients.delete(incoming))
    onConnect([incoming, outgoing])
  })

  const close = () => {
    for (const c of [...clients]) c.ctl.close()
  }

  server.on('close', close)
  server.on('error', close)

  server.listen(options)
  return clients
}
// Serving (TCP):1 ends here
