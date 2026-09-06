import { describe, it, expect } from 'vitest'
import { Decoder, valueEnd } from '../../src/codec/decode.js'
import { Encoder } from '../../src/codec/encode.js'

const enc = new TextEncoder()

/** Build a small multi-value document as CE bytes. */
function sampleDoc() {
  const e = new Encoder()
  e.putNil()
  e.putScalar('number', false, enc.encode('42'))
  e.frame('record', false, () => {
    e.putScalar('symbol', false, enc.encode('point'))
    e.putScalar('number', false, enc.encode('3'))
    e.frame('list', false, () => {
      e.putScalar('number', false, enc.encode('1'))
      e.putScalar('number', true, enc.encode('2'))
    })
  })
  e.putScalar('text', false, enc.encode('done'))
  return e.bytes
}

describe('Decoder — whole buffer', () => {
  it('drains every top-level value', () => {
    const d = new Decoder()
    const vs = d.push(sampleDoc())
    expect(vs.map(v => v.kind)).toEqual(['nil', 'number', 'record', 'text'])
    expect(d.pending).toBe(false)
  })
})

describe('Decoder — chunked feed', () => {
  const doc = sampleDoc()

  it('reassembles the same values at every split point', () => {
    for (let cut = 0; cut <= doc.length; cut++) {
      const d = new Decoder()
      const got = [
        ...d.push(doc.subarray(0, cut)),
        ...d.push(doc.subarray(cut)),
      ]
      expect(got.map(v => v.kind)).toEqual(['nil', 'number', 'record', 'text'])
      expect(d.pending).toBe(false)
    }
  })

  it('reassembles across one-byte feeds', () => {
    const d = new Decoder()
    const got = []
    for (const byte of doc) got.push(...d.push(Uint8Array.of(byte)))
    expect(got.map(v => v.kind)).toEqual(['nil', 'number', 'record', 'text'])
    expect(d.pending).toBe(false)
  })

  it('stays pending mid-value and completes on the rest', () => {
    const d = new Decoder()
    expect(d.push(doc.subarray(0, 4))).toHaveLength(2) // nil, 42
    expect(d.pending).toBe(false)
    d.push(doc.subarray(4, 7)) // record opened, partway into its head
    expect(d.pending).toBe(true)
    const rest = d.push(doc.subarray(7))
    expect(rest.map(v => v.kind)).toEqual(['record', 'text'])
    expect(d.pending).toBe(false)
  })
})

describe('Decoder — limits', () => {
  it('rejects nesting past maxDepth', () => {
    const deep = Uint8Array.of(
      ...new Array(6).fill(0x60),
      0x10,
      ...new Array(6).fill(0xa0)
    )
    expect(() => new Decoder({ maxDepth: 3 }).push(deep)).toThrow(/depth/)
    expect(new Decoder({ maxDepth: 10 }).push(deep)).toHaveLength(1)
  })

  it('caps an unclosed frame at maxValueBytes even with no truncated scalar', () => {
    const d = new Decoder({ maxValueBytes: 8 })
    d.push(Uint8Array.of(0x60)) // open list, nothing truncated
    d.push(Uint8Array.of(0x51, 1, 0x51, 2, 0x51, 3)) // filler bytes, frame still open
    expect(() => d.push(Uint8Array.of(0x51, 4, 0x51, 5))).toThrow(
      /value-size limit/
    )
  })

  it('rejects an over-large scalar from its announced length', () => {
    const d = new Decoder({ maxValueBytes: 4 })
    // text header, medium length 100
    expect(() => d.push(Uint8Array.of(0x37, 100))).toThrow(/value-size limit/)
  })
})

describe('Decoder — compact', () => {
  it('bounds the buffer across a long stream and stays correct', () => {
    const one = (() => {
      const e = new Encoder()
      e.putScalar('bytes', false, new Uint8Array(20))
      return e.bytes
    })()
    const d = new Decoder()
    let count = 0
    for (let i = 0; i < 100; i++) {
      count += d.push(one).length
      d.compact()
      expect(d.buffered).toBe(0)
    }
    expect(count).toBe(100)
  })

  it('is a no-op while a frame is open', () => {
    const d = new Decoder()
    d.push(Uint8Array.of(0x60, 0x10)) // open list + a nil inside
    const before = d.buffered
    d.compact()
    expect(d.buffered).toBe(before)
  })

  it('a view held across compact() refuses to read shifted bytes', () => {
    const d = new Decoder()
    const [nilV, numV] = d.push(sampleDoc())
    expect([...nilV.slice()]).toEqual([0x10]) // fine before
    d.compact()
    expect(() => nilV.slice()).toThrow(/stale/)
    expect(() => numV.payloadBytes).toThrow(/stale/)
    // a value decoded after the compact is fine
    const [again] = new Decoder().push(sampleDoc())
    d.compact() // no-op on the other decoder; `again` is untouched
    expect([...again.slice()]).toEqual([0x10])
  })
})

describe('ValueView', () => {
  const doc = sampleDoc()

  it('borrows the buffer; slice() is its CE span', () => {
    const [nilV] = new Decoder().push(doc.subarray(0, 1))
    expect([...nilV.slice()]).toEqual([0x10])
  })

  it('exposes lazy children and a deferred, memoized validate()', () => {
    const d = new Decoder()
    const vs = d.push(doc)
    const rec = vs[2]
    expect(rec.kind).toBe('record')
    expect(rec.children().map(c => c.kind)).toEqual([
      'symbol',
      'number',
      'list',
    ])
    expect(() => rec.validate()).not.toThrow()
    expect(() => rec.validate()).not.toThrow() // memoized
  })

  it('compare / equals work on the byte span', () => {
    const [a] = new Decoder().push(Uint8Array.of(0x21, 0x31)) // 1
    const [b] = new Decoder().push(Uint8Array.of(0x21, 0x31)) // 1
    const [c] = new Decoder().push(Uint8Array.of(0x21, 0x32)) // 2
    expect(a.equals(b)).toBe(true)
    expect(a.equals(c)).toBe(false)
    expect(a.compare(c)).toBeLessThan(0)
  })

  it('a marked nested element keeps its mark', () => {
    const list = new Decoder().push(doc)[2].children()[2]
    expect(list.children()[1].mark).toBe(true)
  })
})

describe('valueEnd', () => {
  it('finds the end of the first value', () => {
    expect(valueEnd(Uint8Array.of(0x10, 0x10), 0)).toBe(1)
    expect(valueEnd(Uint8Array.of(0x60, 0x10, 0xa0, 0x10), 0)).toBe(3)
  })
})
