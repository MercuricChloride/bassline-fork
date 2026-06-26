//@ts-check
/** @import {Connection} from "./socket.js" */
import net from 'node:net'
import { fromSocket } from './socket.js'

/**
 * Listen for TCP connections, handing each to `onConnect` as a {@link Connection}.
 * Returns the `net.Server`. With no `port`/`path` an ephemeral port is bound —
 * read it back via `server.address().port`.
 * @param {(conn: Connection) => void} onConnect
 * @param {import('node:net').ListenOptions} [options]
 * @param {{ maxValueSize?: number }} [streamOptions]
 * @returns {import('node:net').Server}
 */
export function serve(onConnect, options = {}, streamOptions) {
  const server = net.createServer(socket => {
    onConnect(fromSocket(socket, streamOptions))
  })
  // empty options makes net throw; default to an ephemeral port
  server.listen(
    options.port == null && options.path == null
      ? { ...options, port: 0 }
      : options
  )
  return server
}
