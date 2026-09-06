import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { decode, decodeAll, encode, eq, cmp, Decoder } from '../src/data.js'
import {
  read,
  readValue,
  ReaderError,
  ReaderIncomplete,
} from '../src/text/index.js'

// The shared corpus every implementation runs. corpus.bl is authored in the
// textual syntax with spec-derived bytes; corpus.blb is the same records as a
// bare concatenation of CE. This suite reads the .bl with the text reader,
// runs every case, and checks the .blb still agrees.

const dir = new URL('../../../corpus/', import.meta.url)
const cases = read(readFileSync(new URL('corpus.bl', dir), 'utf8'))
const blb = new Uint8Array(readFileSync(new URL('corpus.blb', dir)))

const byHead = head =>
  cases.filter(c => c.kind === 'record' && c.head.value === head)

/**
 * Feed bytes to a fresh Decoder; report what landed, whether it refused, and
 * whether it stayed pending.
 * @param {Uint8Array} bytes
 */
function land(bytes) {
  const d = new Decoder()
  try {
    const views = d.push(bytes)
    return { views, refused: false, pending: d.pending }
  } catch {
    return { views: [], refused: true, pending: d.pending }
  }
}

const label = s => JSON.stringify(s)

describe('corpus is well-formed', () => {
  it('every case is a record with a known head', () => {
    const heads = new Set([
      'ce',
      'reject',
      'starved',
      'reads',
      'refuses',
      'incomplete',
      'document',
    ])
    expect(cases.length).toBeGreaterThan(100)
    for (const c of cases) {
      expect(c.kind).toBe('record')
      expect(heads.has(c.head.value)).toBe(true)
    }
  })

  it('corpus.blb decodes to the same records as corpus.bl', () => {
    const fromBlb = decodeAll(blb)
    expect(fromBlb.length).toBe(cases.length)
    for (let i = 0; i < cases.length; i++) {
      expect(eq(fromBlb[i], cases[i])).toBe(true)
    }
  })
})

describe('corpus: ce', () => {
  for (const c of byHead('ce')) {
    const value = c.items[2]
    const want = c.items[3].value
    it(c.items[1].value, () => {
      // value encodes to exactly want
      expect([...encode(value)]).toEqual([...want])
      // want lands as exactly one value equal to value
      const l = land(want)
      expect(l.refused).toBe(false)
      expect(l.pending).toBe(false)
      expect(l.views).toHaveLength(1)
      expect(eq(decode(want), value)).toBe(true)
    })
  }
})

describe('corpus: reject', () => {
  for (const c of byHead('reject')) {
    it(c.items[1].value, () => {
      expect(land(c.items[2].value).refused).toBe(true)
    })
  }
})

describe('corpus: starved', () => {
  for (const c of byHead('starved')) {
    it(c.items[1].value, () => {
      const l = land(c.items[2].value)
      expect(l.refused).toBe(false)
      expect(l.views).toHaveLength(0)
      expect(l.pending).toBe(true)
    })
  }
})

describe('corpus: reads', () => {
  for (const c of byHead('reads')) {
    const src = c.items[1].value
    const value = c.items[2]
    it(label(src), () => {
      expect(eq(readValue(src), value)).toBe(true)
    })
  }
})

describe('corpus: refuses', () => {
  for (const c of byHead('refuses')) {
    const src = c.items[1].value
    it(label(src), () => {
      let err
      try {
        readValue(src)
      } catch (e) {
        err = e
      }
      expect(err).toBeInstanceOf(ReaderError)
      expect(err).not.toBeInstanceOf(ReaderIncomplete)
    })
  }
})

describe('corpus: incomplete', () => {
  for (const c of byHead('incomplete')) {
    const src = c.items[1].value
    it(label(src), () => {
      expect(() => readValue(src)).toThrow(ReaderIncomplete)
    })
  }
})

describe('corpus: document', () => {
  for (const c of byHead('document')) {
    const src = c.items[1].value
    const want = [...c.items[2]]
    it(label(src), () => {
      const got = read(src)
      expect(got.length).toBe(want.length)
      for (let i = 0; i < want.length; i++) {
        expect(eq(got[i], want[i])).toBe(true)
      }
    })
  }
})

describe('structural order agrees with CE-byte order across the corpus', () => {
  const values = byHead('ce').map(c => c.items[2])
  it('cmp has the same sign as comparing encode() bytes, for every pair', () => {
    const bytesOf = new Map(values.map(v => [v, encode(v)]))
    const cmpBytes = (a, b) => {
      const n = Math.min(a.length, b.length)
      for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] - b[i]
      return a.length - b.length
    }
    for (const x of values) {
      for (const y of values) {
        expect(Math.sign(cmp(x, y))).toBe(
          Math.sign(cmpBytes(bytesOf.get(x), bytesOf.get(y)))
        )
      }
    }
  })
})
