import { describe, expect, it, vi, beforeEach } from 'vitest'
import { noun, verb } from '@bassline/core'
import { Port, Propagator } from '../src/comms.js'

function send(aPort, ...msgs) {
  for (const m of msgs) aPort.send(m)
}

describe('Port', () => {
  it('receives buffered messages in FIFO order', async () => {
    const port = new Port()
    const [first, second] = [1, 2].map(noun)
    send(port, first, second)

    await expect(port.recv()).resolves.toBe(first)
    await expect(port.recv()).resolves.toBe(second)
  })

  it('drops the oldest message when a bounded buffer overflows', async () => {
    const port = new Port(1)
    const [first, second] = [1, 2].map(noun)
    send(port, first, second)

    await expect(port.recv()).resolves.toBe(second)
  })

  it('does not buffer when size is zero, but still delivers to a waiter', async () => {
    const port = new Port(0)
    const [dropped, delivered] = [1, 2].map(noun)
    port.send(dropped)
    const read = port.recv()
    port.send(delivered)

    await expect(read).resolves.toBe(delivered)
  })

  it('resolves waiting receivers and stops receiving after close', async () => {
    const port = new Port()
    const read = port.recv()

    port.close()
    port.send(noun(123))

    await expect(read).resolves.toBeUndefined()
    await expect(port.recv()).resolves.toBeUndefined()
  })

  it('projects a send word with buffer metadata', async () => {
    const port = new Port(2)
    const projected = port.toWord()
    const payload = noun(123)

    projected.verb(payload)

    expect(projected.noun).toEqual({ size: 2, bounded: true })
    await expect(port.recv()).resolves.toBe(payload)
  })
})

describe('Propagator', () => {
  let propagator, sink

  beforeEach(() => {
    sink = verb(vi.fn())
    propagator = new Propagator()
  })

  it('relays messages to targeted words', () => {
    const payload = noun(true)

    propagator.target(sink)
    propagator.send(payload)

    expect(sink.verb).toHaveBeenCalledTimes(1)
    expect(sink.verb).toHaveBeenCalledWith(payload)
  })

  it('stops sending to removed targets', () => {
    const remove = propagator.target(sink)

    remove()
    propagator.send(noun(true))

    expect(sink.verb).not.toHaveBeenCalled()
  })

  it('lets custom actions emit zero or more messages', () => {
    const [first, second] = [1, 2].map(noun)
    const sink = verb(vi.fn())
    const propagator = new Propagator((_aMsg, send) => {
      send(first)
      send(second)
    })

    propagator.target(sink)
    propagator.send(noun(true))

    expect(sink.verb).toHaveBeenCalledTimes(2)
    expect(sink.verb).toHaveBeenNthCalledWith(1, first)
    expect(sink.verb).toHaveBeenNthCalledWith(2, second)
  })

  it('projects a verb', () => {
    const propagator = new Propagator()
    const sink = verb(vi.fn())
    const payload = noun(true)

    propagator.target(sink)
    propagator.toWord().verb(payload)

    expect(sink.verb).toHaveBeenCalledWith(payload)
  })
})
