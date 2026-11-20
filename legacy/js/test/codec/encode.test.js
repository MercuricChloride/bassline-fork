import { describe, it, expect } from 'vitest'
import { Encoder, CodecError } from '../../src/codec/encode.js'
import { walkEvents } from '../../src/codec/events.js'
import { ByteCursor } from '../../src/codec/buffer.js'

const enc = new TextEncoder()
const hex = u8 => [...u8].map(b => b.toString(16).padStart(2, '0')).join('')

describe('Encoder byte output', () => {
  it('writes nil, marked and plain', () => {
    const e = new Encoder()
    e.putNil()
    e.putNil(true)
    expect(hex(e.bytes)).toBe('1018')
  })

  it('writes a scalar with an inline length', () => {
    const e = new Encoder()
    e.putScalar('text', false, enc.encode('hi'))
    expect(hex(e.bytes)).toBe('326869')
  })

  it('writes a marked scalar', () => {
    const e = new Encoder()
    e.putScalar('symbol', true, enc.encode('go'))
    expect(hex(e.bytes)).toBe('4a676f')
  })

  it('writes a frame as header ... END', () => {
    const e = new Encoder()
    e.frame('list', false, () => {
      e.putScalar('number', false, enc.encode('1'))
      e.putScalar('number', false, enc.encode('2'))
    })
    expect(hex(e.bytes)).toBe('6021312132a0') // 60 21 31 21 32 A0
  })

  it('uses the two-byte length form at 7 and the four-byte form at 255', () => {
    const seven = new Encoder()
    seven.putScalar('bytes', false, new Uint8Array(7))
    expect(hex(seven.bytes).slice(0, 4)).toBe('5707')

    const big = new Encoder()
    big.putScalar('bytes', false, new Uint8Array(255))
    expect(hex(big.bytes).slice(0, 12)).toBe('57ff000000ff')
  })

  it('writes a large payload whole (append path), not byte by byte', () => {
    const payload = Uint8Array.from({ length: 5000 }, (_, i) => i & 0xff)
    const e = new Encoder()
    e.putScalar('bytes', false, payload)
    const out = e.bytes
    expect(out.length).toBe(6 + 5000) // 0x57 0xff + 4 length bytes + payload
    expect([...out.subarray(6)]).toEqual([...payload])
  })

  it.each([0, 1, 6, 7, 8, 254, 255, 256, 300, 66000])(
    'the length prefix round-trips at payload length %i',
    len => {
      const payload = Uint8Array.from({ length: len }, (_, i) => (i * 7) & 0xff)
      const e = new Encoder()
      e.putScalar('bytes', false, payload)
      const out = e.bytes
      const [ev] = [...walkEvents(new ByteCursor(out))]
      expect(ev).toMatchObject({ t: 'atom', kind: 'bytes', payloadLen: len })
      expect([...out.subarray(ev.payloadAt)]).toEqual([...payload])
    }
  )
})

describe('Encoder discipline', () => {
  it('refuses .bytes while a frame is open', () => {
    const e = new Encoder()
    e.open('dict')
    expect(() => e.bytes).toThrow(CodecError)
    expect(e.pending).toBe(true)
  })

  it('refuses close with nothing open', () => {
    expect(() => new Encoder().close()).toThrow(CodecError)
  })

  it('refuses a scalar kind for open and a frame kind for putScalar', () => {
    expect(() => new Encoder().open('text')).toThrow(CodecError)
    expect(() => new Encoder().putScalar('list', false, [])).toThrow(CodecError)
  })
})

describe('Encoder output re-walks', () => {
  it('a nested value encodes to events that balance', () => {
    const e = new Encoder()
    e.frame('record', true, () => {
      e.putScalar('symbol', false, enc.encode('msg'))
      e.frame('dict', false, () => {
        e.putScalar('symbol', false, enc.encode('k'))
        e.putScalar('symbol', false, enc.encode('v'))
      })
    })
    const kinds = [...walkEvents(new ByteCursor(e.bytes))].map(x => x.t)
    expect(kinds).toEqual([
      'open',
      'atom',
      'open',
      'atom',
      'atom',
      'close',
      'close',
    ])
  })
})
