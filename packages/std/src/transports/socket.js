// [[file:../../../../book.org::*Socket][Socket:1]]
import net from 'node:net'
import { verb } from '@bassline/core'
import { Port } from '../comms.js'
import defaultFrame from '../frame/jsonl.js'

export function fromSocket(socket, createFrame = defaultFrame) {
  const outgoing = verb(m => socket.write(frame.format(m)))
  const incoming = new Port()
  const frame = createFrame(incoming.toWord())

  incoming.ctl.onClose(() => socket.destroy())
  socket.on('data', chunk => frame.readChunk(chunk.toString()))
  socket.on('close', outgoing.close)
  socket.on('end', outgoing.close)
  socket.on('error', outgoing.close)

  return [incoming, outgoing]
}

export function connect(options = {}, createFrame = defaultFrame) {
  return fromSocket(net.createConnection(options), createFrame)
}
// Socket:1 ends here
