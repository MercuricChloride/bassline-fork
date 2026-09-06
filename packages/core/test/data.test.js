import { describe, it, expect } from 'vitest'
import {
  eq,
  cmp,
  isData,
  encode,
  decode,
  decodeAll,
  withMark,
  marked,
  hasMark,
  at,
  contains,
  assoc,
  dissoc,
  nil,
  int,
  text,
  symbol,
  list,
  dict,
  set,
} from '../src/data.js'

const hex = u8 =>
  [...u8]
    .map(b => b.toString(16).padStart(2, '0'))
    .join(' ')
    .toUpperCase()

const act = v => withMark(v, true)

// The wire format itself is covered exhaustively by test/corpus.test.js
// against corpus/corpus.bl. These tests exercise the value API.

describe('the mark', () => {
  it('withMark sets it; a matching call is a no-op that returns the same handle', () => {
    const m = act(int(1n))
    expect(marked(m)).toBe(true)
    expect(withMark(m, true)).toBe(m)
    expect(withMark(int(1n), false)).toEqual(int(1n))
  })

  it('withMark(v, false) inverts it', () => {
    expect(eq(withMark(act(int(1n)), false), int(1n))).toBe(true)
    expect(eq(withMark(int(1n), false), int(1n))).toBe(true)
  })

  it('is idempotent', () => {
    expect(eq(act(act(int(1n))), act(int(1n)))).toBe(true)
  })

  it('changes the canonical encoding and identity', () => {
    expect(eq(act(int(1n)), int(1n))).toBe(false)
    expect(hex(encode(act(int(1n))))).not.toBe(hex(encode(int(1n))))
  })

  it('hasMark / isData see the mark anywhere in the tree', () => {
    expect(hasMark(list([act(int(1n))]))).toBe(true)
    expect(isData(list([act(int(1n))]))).toBe(false)
    expect(isData(list([int(1n)]))).toBe(true)
  })

  it('a frame keeps its body when re-marked', () => {
    const l = list([int(1n), int(2n)])
    const m = withMark(l, true)
    expect(eq(withMark(m, false), l)).toBe(true)
    expect([...m].length).toBe(2)
  })
})

describe('equality and order', () => {
  it('eq is total and honours the mark', () => {
    expect(eq(act(int(1n)), act(int(1n)))).toBe(true)
    expect(eq(act(int(1n)), int(1n))).toBe(false)
  })

  it('distinguishes the int 1 from the text "1" (same payload bytes)', () => {
    expect(eq(int(1n), text('1'))).toBe(false)
    expect(cmp(int(1n), text('1'))).toBeLessThan(0) // number tag < text tag
  })

  it('distinguishes a symbol from a same-spelled text', () => {
    expect(eq(symbol('x'), text('x'))).toBe(false)
  })

  it('distinguishes {k: nil} from {}', () => {
    expect(eq(dict([[symbol('k'), nil()]]), dict([]))).toBe(false)
  })

  it('cmp is CE order (shortlex), not numeric order', () => {
    // the decimal spellings sort by length first: "1" "2" before "-1" "10",
    // and "-1" before "10" because '-' (0x2D) < '1' (0x31)
    const sorted = [int(2n), int(10n), int(-1n), int(1n)].sort(cmp)
    expect(sorted.map(v => Number(v.value))).toEqual([1, 2, -1, 10])
  })
})

describe('BInt representation', () => {
  it('rounds a decoded integer through the smallest representation', () => {
    expect(typeof decode(encode(int(5n))).value).toBe('number')
    const big = 10n ** 40n
    expect(typeof decode(encode(int(big))).value).toBe('bigint')
    expect(decode(encode(int(big))).value).toBe(big)
  })
})

describe('text & symbol', () => {
  it('reject lone surrogates at construction', () => {
    expect(() => text('\uD800')).toThrow()
    expect(() => symbol('\uDC00')).toThrow()
  })
})

describe('length tiers', () => {
  it('uses the four-byte length form past 254', () => {
    const v = text('a'.repeat(300))
    const ce = encode(v)
    expect(hex(ce.subarray(0, 6))).toBe('37 FF 00 00 01 2C')
    expect(ce.length).toBe(306)
    expect(eq(decode(ce), v)).toBe(true)
  })
})

describe('decode limits', () => {
  it('honours a per-call value-size limit', () => {
    const ce = encode(text('a'.repeat(300)))
    expect(() => decode(ce, { maxValueBytes: 100 })).toThrow(/value-size limit/)
    expect(() => decode(ce, { maxValueBytes: 400 })).not.toThrow()
  })

  it('rejects nesting past the depth limit', () => {
    const deep = Uint8Array.of(
      ...new Array(5).fill(0x60),
      0x10,
      ...new Array(5).fill(0xa0)
    )
    expect(() => decode(deep, { maxDepth: 3 })).toThrow(/depth/)
    expect(() => decode(deep, { maxDepth: 10 })).not.toThrow()
  })

  it('decode refuses trailing bytes; decodeAll takes them as more values', () => {
    const two = Uint8Array.of(0x10, 0x10)
    expect(() => decode(two)).toThrow()
    expect(decodeAll(two).map(v => v.kind)).toEqual(['nil', 'nil'])
  })
})

describe('dictionaries', () => {
  it('deduplicates keys canonically, last write wins', () => {
    const d = dict([
      [symbol('a'), int(1n)],
      [symbol('a'), int(2n)],
    ])
    expect(d.size).toBe(1)
    expect(eq(at(d, symbol('a')), int(2n))).toBe(true)
  })

  it('sorts canonically regardless of construction order', () => {
    const a = dict([
      [symbol('a'), int(1n)],
      [symbol('b'), int(2n)],
    ])
    const b = dict([
      [symbol('b'), int(2n)],
      [symbol('a'), int(1n)],
    ])
    expect(eq(a, b)).toBe(true)
  })

  it('allows a marked key, and a marked value makes the dict non-data', () => {
    const k = dict([[act(symbol('a')), int(1n)]])
    expect(eq(decode(encode(k)), k)).toBe(true)
    const v = dict([[symbol('a'), act(int(1n))]])
    expect(isData(v)).toBe(false)
    expect(eq(at(v, symbol('a')), act(int(1n)))).toBe(true)
  })

  it('at / contains / assoc / dissoc', () => {
    const d = dict([[symbol('a'), int(1n)]])
    expect(at(d, symbol('z'))).toBeUndefined()
    expect(contains(d, symbol('a'))).toBe(true)
    const d2 = assoc(d, symbol('b'), int(2n))
    expect(d2.size).toBe(2)
    expect(d.size).toBe(1) // unchanged
    expect(eq(dissoc(d2, symbol('a')), dict([[symbol('b'), int(2n)]]))).toBe(
      true
    )
  })
})

describe('sets', () => {
  it('deduplicates members canonically and is order-insensitive', () => {
    expect(set([int(1n), int(1n)]).size).toBe(1)
    expect(eq(set([int(1n), int(2n)]), set([int(2n), int(1n)]))).toBe(true)
  })

  it('at returns the stored member; contains checks membership', () => {
    const a = int(1n)
    const s = set([a])
    expect(at(s, int(1n))).toBe(a)
    expect(at(s, int(2n))).toBeUndefined()
    expect(contains(s, int(1n))).toBe(true)
  })

  it('assoc / dissoc', () => {
    const s = set([int(1n)])
    expect(assoc(s, int(2n)).size).toBe(2)
    expect(eq(dissoc(assoc(s, int(2n)), int(1n)), set([int(2n)]))).toBe(true)
  })
})
