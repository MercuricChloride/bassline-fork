import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { walkEvents, CodecError } from '../../src/codec/events.js'
import { ByteBuffer, ByteCursor, Starved } from '../../src/codec/buffer.js'

const BLB = new URL('../../../../corpus/corpus.blb', import.meta.url)

const bytesOf = s =>
  Uint8Array.from(
    s
      .trim()
      .split(/\s+/)
      .map(h => parseInt(h, 16))
  )

const events = (bytes, opts) => {
  const cur = new ByteCursor(bytes)
  return [...walkEvents(cur, opts)]
}

describe('walkEvents over hand vectors', () => {
  it('sees a nil', () => {
    expect(events(bytesOf('10'))).toEqual([{ t: 'nil', at: 0, mark: false }])
  })

  it('carries the mark on a nil', () => {
    expect(events(bytesOf('18'))[0].mark).toBe(true)
  })

  it('sees an inline-length atom with its payload span', () => {
    // "hi" text: 32 68 69
    expect(events(bytesOf('32 68 69'))).toEqual([
      {
        t: 'atom',
        at: 0,
        kind: 'text',
        mark: false,
        payloadAt: 1,
        payloadLen: 2,
      },
    ])
  })

  it('resolves a medium (two-byte) length', () => {
    const bytes = Uint8Array.of(0x37, 0x07, ...new Array(7).fill(0x61))
    expect(events(bytes)).toEqual([
      {
        t: 'atom',
        at: 0,
        kind: 'text',
        mark: false,
        payloadAt: 2,
        payloadLen: 7,
      },
    ])
  })

  it('resolves a large (four-byte) length', () => {
    const n = 300
    const bytes = Uint8Array.of(
      0x37,
      0xff,
      0,
      0,
      (n >> 8) & 0xff,
      n & 0xff,
      ...new Array(n).fill(0x61)
    )
    const [e] = events(bytes)
    expect(e).toMatchObject({ t: 'atom', payloadAt: 6, payloadLen: n })
  })

  it('walks a frame as open ... close', () => {
    // [1 2] : 60 21 31 21 32 A0
    expect(events(bytesOf('60 21 31 21 32 A0')).map(e => e.t)).toEqual([
      'open',
      'atom',
      'atom',
      'close',
    ])
  })

  it('yields siblings at the top level', () => {
    expect(events(bytesOf('10 10 10')).map(e => e.t)).toEqual([
      'nil',
      'nil',
      'nil',
    ])
  })
})

describe('walkEvents structural rejects', () => {
  it.each([
    ['invalid tag 0x0', '00'],
    ['invalid tag 0xF', 'F0'],
    ['END carrying bits', 'A1'],
    ['nil with length bits', '11'],
    ['frame header with length bits', '61'],
    ['non-minimal two-byte length', '37 05 61 62 63 64 65'],
    [
      'non-minimal four-byte length',
      '37 FF 00 00 00 08 61 61 61 61 61 61 61 61',
    ],
  ])('throws CodecError on %s', (_label, hex) => {
    expect(() => events(bytesOf(hex))).toThrow(CodecError)
  })
})

describe('walkEvents starvation', () => {
  it.each([
    ['a short scalar payload', '33 61 62'],
    ['a medium length with no length byte', '37'],
    ['a large length half-arrived', '37 FF 00 00'],
  ])('throws Starved on %s (a truncated atom)', (_label, hex) => {
    expect(() => events(bytesOf(hex))).toThrow(Starved)
  })

  it('does not starve on an unclosed frame — it ends after the open', () => {
    // an unbalanced open is the resumable decoder's concern (it stays pending),
    // not the byte walker's: walkEvents just runs out of bytes cleanly
    expect(events(bytesOf('60 21 31 21 32')).map(e => e.t)).toEqual([
      'open',
      'atom',
      'atom',
    ])
  })

  it('over a ByteBuffer, parks at the partial value and resumes on more bytes', () => {
    const buf = new ByteBuffer()
    buf.append(bytesOf('10 33 61 62')) // nil, then a truncated text
    const cur = new ByteCursor(buf)
    const seen = []
    try {
      for (const e of walkEvents(cur)) seen.push(e)
    } catch (err) {
      expect(err).toBeInstanceOf(Starved)
    }
    expect(seen.map(e => e.t)).toEqual(['nil'])
    expect(cur.pos).toBe(1) // parked at the text header, not past it

    buf.append(bytesOf('63')) // "abc" now complete
    expect([...walkEvents(cur)]).toEqual([
      {
        t: 'atom',
        at: 1,
        kind: 'text',
        mark: false,
        payloadAt: 2,
        payloadLen: 3,
      },
    ])
  })

  it('reports outstanding payload bytes on Starved.owed', () => {
    try {
      events(bytesOf('33 61')) // text of length 3, one byte present
    } catch (err) {
      expect(err.owed).toBe(2)
    }
  })
})

describe('walkEvents over the shared corpus', () => {
  it('walks every byte of corpus.blb into balanced, terminated events', () => {
    const buf = new Uint8Array(readFileSync(BLB))
    const cur = new ByteCursor(buf)
    let depth = 0
    let topLevel = 0
    for (const e of walkEvents(cur)) {
      if (e.t === 'atom') {
        expect(e.payloadAt + e.payloadLen).toBeLessThanOrEqual(buf.length)
      }
      if (e.t === 'open') depth++
      else if (e.t === 'close') {
        depth--
        expect(depth).toBeGreaterThanOrEqual(0)
        if (depth === 0) topLevel++
      } else if (depth === 0) topLevel++ // a bare nil / atom at the top
    }
    expect(depth).toBe(0)
    expect(cur.pos).toBe(buf.length)
    expect(topLevel).toBeGreaterThan(100) // ~200 corpus case records
  })

  it('honours a lowered maxValueBytes', () => {
    const buf = new Uint8Array(readFileSync(BLB))
    expect(() => [
      ...walkEvents(new ByteCursor(buf), { maxValueBytes: 8 }),
    ]).toThrow(/value-size limit/)
  })
})
