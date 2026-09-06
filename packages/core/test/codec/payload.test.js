import { describe, it, expect } from 'vitest'
import {
  isCanonicalInt,
  isWellFormedUtf8,
  decodeUtf8,
  compareBytes,
  compareShortlex,
} from '../../src/codec/payload.js'

const enc = new TextEncoder()
const b = s => enc.encode(s)

describe('isCanonicalInt', () => {
  it.each(['0', '1', '9', '10', '255', '-1', '-255', '1234567890'])(
    'accepts %s',
    s => expect(isCanonicalInt(b(s))).toBe(true)
  )

  it.each([
    '',
    '-',
    '-0',
    '00',
    '01',
    '007',
    '-01',
    '1a',
    'x',
    '+5',
    '1.5',
    ' 1',
  ])('rejects %s', s => expect(isCanonicalInt(b(s))).toBe(false))
})

describe('isWellFormedUtf8', () => {
  it('accepts ascii and multi-byte text', () => {
    expect(isWellFormedUtf8(b('hi'))).toBe(true)
    expect(isWellFormedUtf8(b('héllo 😀'))).toBe(true)
    expect(isWellFormedUtf8(new Uint8Array(0))).toBe(true)
  })

  it('rejects a lone high byte, an overlong form, and a surrogate', () => {
    expect(isWellFormedUtf8(Uint8Array.of(0xff))).toBe(false)
    expect(isWellFormedUtf8(Uint8Array.of(0xc0, 0x80))).toBe(false)
    expect(isWellFormedUtf8(Uint8Array.of(0xed, 0xa0, 0x80))).toBe(false)
  })

  it('decodeUtf8 throws on the same', () => {
    expect(() => decodeUtf8(Uint8Array.of(0xff))).toThrow()
    expect(decodeUtf8(b('ok'))).toBe('ok')
  })
})

describe('compareBytes', () => {
  it('is bytewise then shorter-first', () => {
    expect(compareBytes(b('a'), b('b'))).toBeLessThan(0)
    expect(compareBytes(b('a'), b('ab'))).toBeLessThan(0)
    expect(compareBytes(b('ab'), b('a'))).toBeGreaterThan(0)
    expect(compareBytes(b('ab'), b('ab'))).toBe(0)
  })

  it('orders a shorter frame after a longer one it prefixes (0xA0 > any header)', () => {
    // [a] vs [a b]: END (A0) sits where [a b] still has a header
    const short = Uint8Array.of(0x60, 0x41, 0x61, 0xa0)
    const long = Uint8Array.of(0x60, 0x41, 0x61, 0x41, 0x62, 0xa0)
    expect(compareBytes(short, long)).toBeGreaterThan(0)
  })
})

describe('compareShortlex', () => {
  it('is length-first then bytewise', () => {
    expect(compareShortlex(b('z'), b('aa'))).toBeLessThan(0)
    expect(compareShortlex(b('aa'), b('ab'))).toBeLessThan(0)
    expect(compareShortlex(b('ab'), b('ab'))).toBe(0)
  })
})
