import { describe, it, expect } from 'vitest'
import {
  BValue,
  BAtom,
  BFrame,
  isValue,
  isAtom,
  isFrame,
} from '../../src/value/value.js'
import {
  nil,
  int,
  text,
  symbol,
  bytes,
  list,
  record,
  dict,
  set,
} from '../../src/value/build.js'
import { encode } from '../../src/value/ce.js'
import { compareBytes } from '../../src/codec/payload.js'

const b = (...n) => bytes(Uint8Array.of(...n))

describe('construction & predicates', () => {
  it('every constructor yields a BValue', () => {
    for (const v of [
      nil(),
      int(1),
      text('x'),
      symbol('x'),
      b(1),
      list([]),
      record([symbol('r')]),
      dict([]),
      set([]),
    ]) {
      expect(isValue(v)).toBe(true)
      expect(v instanceof BValue).toBe(true)
    }
  })

  it('isAtom / isFrame partition the kinds', () => {
    expect(isAtom(int(1))).toBe(true)
    expect(isAtom(list([]))).toBe(false)
    expect(isFrame(dict([]))).toBe(true)
    expect(int(1) instanceof BAtom).toBe(true)
    expect(list([]) instanceof BFrame).toBe(true)
  })

  it('a record needs a head', () => {
    expect(() => record([])).toThrow()
    expect(record([symbol('r')]).head).toEqual(symbol('r'))
  })

  it('text / symbol reject lone surrogates', () => {
    expect(() => text('\uD800')).toThrow()
    expect(() => symbol('\uDC00')).toThrow()
  })

  it('bytes copies its input', () => {
    const src = Uint8Array.of(1, 2, 3)
    const v = b(1, 2, 3)
    src.fill(9)
    expect([...encode(v)]).toEqual([0x53, 1, 2, 3])
  })
})

describe('BInt representation', () => {
  it('keeps a safe integer as a number', () => {
    expect(typeof int(42).value).toBe('number')
    expect(typeof int(42n).value).toBe('number') // demoted
    expect(int(42).value).toBe(42)
  })

  it('grows to bigint past the safe range', () => {
    const big = 10n ** 30n
    expect(typeof int(big).value).toBe('bigint')
    expect(int(big).value).toBe(big)
  })

  it('a number and its bigint spelling are equal', () => {
    expect(int(5).equals(int(5n))).toBe(true)
    expect(int(0).equals(int(0n))).toBe(true)
  })

  it('refuses a non-integer number', () => {
    expect(() => int(1.5)).toThrow()
    expect(() => int(NaN)).toThrow()
  })

  it('toBigInt normalizes', () => {
    expect(int(7).toBigInt()).toBe(7n)
    expect(int(10n ** 40n).toBigInt()).toBe(10n ** 40n)
  })
})

describe('compare / equals reproduce CE order', () => {
  const samples = [
    nil(),
    nil(true),
    int(0),
    int(1),
    int(-1),
    int(10),
    int(255),
    int(10n ** 30n),
    text(''),
    text('hi'),
    symbol('go'),
    symbol('go', true),
    b(),
    b(0xff),
    list([]),
    list([int(1)]),
    list([int(1), int(2)]),
    record([symbol('f')]),
    record([symbol('f'), int(1)]),
    dict([]),
    dict([[symbol('a'), int(1)]]),
    set([]),
    set([int(1), int(2)]),
    set([b(0xa0)]),
  ]

  it('matches the sign of comparing CE bytes, for every pair', () => {
    for (const x of samples) {
      for (const y of samples) {
        expect(Math.sign(x.compare(y))).toBe(
          Math.sign(compareBytes(encode(x), encode(y)))
        )
      }
    }
  })

  it('equals iff the CE bytes are equal', () => {
    for (const x of samples) {
      for (const y of samples) {
        expect(x.equals(y)).toBe(compareBytes(encode(x), encode(y)) === 0)
      }
    }
  })

  it('kind outranks payload (int 1 vs text "1")', () => {
    expect(int(1).equals(text('1'))).toBe(false)
    expect(Math.sign(int(1).compare(text('1')))).toBe(-1) // number tag < text tag
  })

  it('mark rides inside the type byte (mixed set stays ordered)', () => {
    const s = set([int(1), nil(true)])
    expect(s.equals(decodeRoundTrip(s))).toBe(true)
  })

  it('a shorter frame sorts after a longer one it prefixes', () => {
    expect(Math.sign(list([int(1)]).compare(list([int(1), int(2)])))).toBe(1)
  })
})

// tiny helper: re-decode via the new pipeline
import { decode } from '../../src/value/view.js'
function decodeRoundTrip(v) {
  return decode(encode(v))
}
