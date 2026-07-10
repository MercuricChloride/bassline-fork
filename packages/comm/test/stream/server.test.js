import { describe, it, expect } from 'vitest'
import { once } from 'node:events'
import net from 'node:net'
import {
  nil,
  int,
  string,
  list,
  symbol,
  record,
  withMark,
  eq,
  encode,
} from '@bassline/core/data'
import { serve } from '../../src/stream/server.js'
import { connect } from '../../src/stream/socket.js'

// Start a server and expose its port plus a promise for the first connection.
const startServer = async () => {
  let resolveConn
  const firstConn = new Promise(r => (resolveConn = r))
  const server = serve(conn => resolveConn(conn))
  await once(server, 'listening')
  return { server, port: server.address().port, firstConn }
}

// Collect values from a Connection until `count` arrive, then resolve.
const collect = async (conn, count) => {
  const got = []
  for await (const v of conn.values) {
    got.push(v)
    if (got.length === count) break
  }
  return got
}

describe('serve / connect over TCP', () => {
  it('round-trips a sequence of values across a real socket', async () => {
    const sent = [
      int(42n),
      string('hello'),
      list([int(1n), int(2n), int(3n)]),
      record([symbol('point'), int(3n), int(4n)]),
      withMark(list([nil()])), // actionable
    ]

    const { server, port, firstConn } = await startServer()
    const client = connect({ port })
    for (const v of sent) client.send(v)

    const got = await collect(await firstConn, sent.length)
    client.close()
    server.close()

    expect(got.length).toBe(sent.length)
    sent.forEach((v, i) => expect(eq(got[i], v)).toBe(true))
  })

  it('reassembles a value fragmented across packets', async () => {
    const big = record([symbol('blob'), string('x'.repeat(2000))])
    const wire = encode(big)

    const { server, port, firstConn } = await startServer()

    // split the value into two writes so the decoder buffers across `data` events
    const raw = net.createConnection({ port })
    await once(raw, 'connect')
    raw.write(wire.subarray(0, 3))
    await new Promise(r => setTimeout(r, 20))
    raw.write(wire.subarray(3))

    const [got] = await collect(await firstConn, 1)
    raw.destroy()
    server.close()

    expect(eq(got, big)).toBe(true)
  })

  it('rejects a peer that truncates a value before FIN', async () => {
    const wire = encode(string('incomplete'))

    const { server, port, firstConn } = await startServer()

    const raw = net.createConnection({ port })
    await once(raw, 'connect')
    raw.write(wire.subarray(0, wire.length - 2)) // hold back the tail
    raw.end() // FIN with a partial value buffered

    await expect(collect(await firstConn, 1)).rejects.toThrow(/mid-value/)
    server.close()
  })
})
