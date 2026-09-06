import { describe, it, expect } from 'vitest'
import {
  CodecError,
  KIND,
  KIND_OF_TAG,
  END,
  MARK_BIT,
  readHeader,
  headerByte,
  isScalarKind,
  isFrameKind,
} from '../../src/codec/header.js'

describe('KIND numbering', () => {
  it('is the documented tag table', () => {
    expect(KIND).toEqual({
      nil: 1,
      number: 2,
      text: 3,
      symbol: 4,
      bytes: 5,
      list: 6,
      record: 7,
      dict: 8,
      set: 9,
    })
  })

  it('KIND_OF_TAG inverts KIND', () => {
    for (const [name, tag] of Object.entries(KIND)) {
      expect(KIND_OF_TAG[tag]).toBe(name)
    }
  })
})

describe('readHeader', () => {
  it('round-trips every kind, both marks, for a zero length', () => {
    for (const kind of Object.keys(KIND)) {
      for (const mark of [false, true]) {
        const b = headerByte(kind, mark, 0)
        expect(readHeader(b)).toEqual({ kind, mark, lenBits: 0 })
      }
    }
  })

  it('reads the inline length bits of a scalar', () => {
    const b = headerByte('text', false, 5)
    expect(readHeader(b)).toEqual({ kind: 'text', mark: false, lenBits: 5 })
  })

  it('caps the inline length bits at 7 (the extension signal)', () => {
    expect(readHeader(headerByte('bytes', false, 200)).lenBits).toBe(7)
  })

  it('rejects the invalid tags 0x0 and 0xB..0xF', () => {
    for (const b of [0x00, 0x08, 0xb0, 0xc0, 0xf8]) {
      expect(() => readHeader(b)).toThrow(CodecError)
    }
  })

  it('rejects length bits on nil and on a frame header', () => {
    expect(() => readHeader((KIND.nil << 4) | 1)).toThrow(/length bits/)
    expect(() => readHeader((KIND.list << 4) | 1)).toThrow(/length bits/)
    expect(() => readHeader((KIND.dict << 4) | 4)).toThrow(/length bits/)
  })

  it('reads the mark bit independent of the tag', () => {
    expect(readHeader(headerByte('symbol', true, 0)).mark).toBe(true)
    expect((headerByte('symbol', true, 0) & MARK_BIT) !== 0).toBe(true)
  })
})

describe('kind predicates', () => {
  it('partition the nine kinds', () => {
    const scalars = ['number', 'text', 'symbol', 'bytes']
    const frames = ['list', 'record', 'dict', 'set']
    for (const k of scalars) expect(isScalarKind(k)).toBe(true)
    for (const k of frames) expect(isFrameKind(k)).toBe(true)
    expect(isScalarKind('nil')).toBe(false)
    expect(isFrameKind('nil')).toBe(false)
  })
})

it('END is 0xA0', () => {
  expect(END).toBe(0xa0)
})
