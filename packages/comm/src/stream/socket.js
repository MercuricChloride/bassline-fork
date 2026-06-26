//@ts-check
/** @import {Value} from "@bassline/core/data" */
import net from 'node:net'
import { encode } from '@bassline/core/data'
import { decodeStream } from './transform.js'

/**
 * @typedef {object} Connection
 * @property {AsyncIterable<Value>} values decoded inbound values
 * @property {(value: Value) => boolean} send encode and write one value
 * @property {() => void} close tear down the socket
 * @property {import('node:net').Socket} socket the underlying socket
 */

/**
 * Adapt a connected socket into a stream of Values: pipe inbound bytes through
 * {@link decodeStream} (self-framing, no delimiter), encode outbound values
 * straight to the socket.
 * @param {import('node:net').Socket} socket
 * @param {{ maxValueSize?: number }} [options]
 * @returns {Connection}
 */
export function fromSocket(socket, options = {}) {
  const values = socket.pipe(decodeStream(options))
  // pipe() ends the value stream on FIN but doesn't forward source errors.
  socket.on('error', err => values.destroy(err))
  return {
    values,
    send: value => socket.write(encode(value)),
    close: () => socket.destroy(),
    socket,
  }
}

/**
 * Dial a TCP endpoint and adapt it via {@link fromSocket}.
 * @param {import('node:net').NetConnectOpts} options
 * @param {{ maxValueSize?: number }} [streamOptions]
 * @returns {Connection}
 */
export function connect(options, streamOptions) {
  return fromSocket(net.createConnection(options), streamOptions)
}
