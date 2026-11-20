import { describe, it, expect } from 'vitest'
import { ByteBuffer, ByteCursor } from '../../src/codec/buffer.js'

describe('ByteBuffer', () => {
  it('push appends one byte, growing as needed', () => {
    const b = new ByteBuffer()
    for (let i = 0; i < 500; i++) b.push(i & 0xff)
    expect(b.length).toBe(500)
    expect([...b.bytes()]).toEqual(
      Array.from({ length: 500 }, (_, i) => i & 0xff)
    )
  })

  it('mixes push and append', () => {
    const b = new ByteBuffer()
    b.push(0xaa)
    b.append(Uint8Array.of(1, 2, 3))
    b.push(0xbb)
    expect([...b.bytes()]).toEqual([0xaa, 1, 2, 3, 0xbb])
  })

  it('generation moves only when dropFront shifts bytes', () => {
    const b = new ByteBuffer()
    const g0 = b.generation
    b.push(1)
    b.append(Uint8Array.of(2, 3, 4, 5)) // a grow does not count
    expect(b.generation).toBe(g0)
    b.dropFront(0) // a no-op does not count
    expect(b.generation).toBe(g0)
    b.dropFront(2)
    expect(b.generation).toBe(g0 + 1)
  })

  it('appends and reports its live bytes', () => {
    const b = new ByteBuffer()
    expect(b.length).toBe(0)
    b.append(Uint8Array.of(1, 2, 3))
    b.append(Uint8Array.of(4, 5))
    expect(b.length).toBe(5)
    expect([...b.bytes()]).toEqual([1, 2, 3, 4, 5])
  })

  it('holds contents across many growth steps', () => {
    const b = new ByteBuffer()
    const expected = []
    for (let i = 0; i < 1000; i++) {
      b.append(Uint8Array.of(i & 0xff))
      expected.push(i & 0xff)
    }
    expect(b.length).toBe(1000)
    expect([...b.bytes()]).toEqual(expected)
  })

  it('dropFront shifts the remainder to the front', () => {
    const b = new ByteBuffer()
    b.append(Uint8Array.of(1, 2, 3, 4, 5))
    b.dropFront(2)
    expect([...b.bytes()]).toEqual([3, 4, 5])
    b.append(Uint8Array.of(6))
    expect([...b.bytes()]).toEqual([3, 4, 5, 6])
  })

  it('dropFront past the end clears it; a non-positive drop is a no-op', () => {
    const b = new ByteBuffer()
    b.append(Uint8Array.of(1, 2))
    b.dropFront(0)
    expect(b.length).toBe(2)
    b.dropFront(99)
    expect(b.length).toBe(0)
  })

  it('a bytes() view taken before dropFront is stale afterwards', () => {
    const b = new ByteBuffer()
    b.append(Uint8Array.of(1, 2, 3, 4))
    const view = b.bytes()
    b.dropFront(2) // shifts in place
    expect([...view.subarray(0, 2)]).toEqual([3, 4]) // the view now sees shifted bytes
  })

  it('pre-allocates when given a capacity', () => {
    const b = new ByteBuffer(128)
    expect(b.length).toBe(0)
    b.append(new Uint8Array(100))
    expect(b.length).toBe(100)
  })
})

describe('ByteCursor', () => {
  it('over a fixed Uint8Array, bytes is that array', () => {
    const arr = Uint8Array.of(9, 8, 7)
    const c = new ByteCursor(arr, 1)
    expect(c.bytes).toBe(arr)
    expect(c.pos).toBe(1)
    expect(c.remaining).toBe(2)
  })

  it('over a ByteBuffer, bytes follows the growing live range', () => {
    const b = new ByteBuffer()
    const c = new ByteCursor(b)
    expect(c.remaining).toBe(0)
    b.append(Uint8Array.of(1, 2, 3))
    expect([...c.bytes]).toEqual([1, 2, 3])
    expect(c.remaining).toBe(3)
    c.pos = 2
    expect(c.remaining).toBe(1)
  })
})
