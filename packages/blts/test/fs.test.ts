import { createHash } from 'node:crypto'
import fs from 'node:fs'
import { describe, expect, it } from 'vitest'
import {
  cuts,
  encode,
  files,
  INLINE_MOST,
  print,
  readValue,
  Refused,
  Search,
  value,
  type Value,
} from '../src/index.ts'
import { inputs } from './fs-inputs.ts'

const {
  digestOf,
  verifies,
  contentOf,
  fileEntry,
  dirEntry,
  linkEntry,
  tree,
  named,
  checked,
  holding,
  missing,
  bytesOf,
  listing,
  walk,
} = files()

const read = (t: string) => readValue(value, t)
const chunkOf = (b: Uint8Array) =>
  value.record([value.sym('chunk'), value.bytes(b)])
const said = (vs: Iterable<Value>) => [...vs].map(v => print(v))

/** A search from a digest to every value in `vs`, whatever it digests: a source that lies. */
const liar = (vs: Value[]) => new Search<Value, Value>(() => vs)

/** Everything a file's content needs held: the content and its chunks. */
const stored = (data: Uint8Array) => {
  const { content, chunks } = contentOf(data)
  return { d: digestOf(content), held: [content, ...chunks] }
}

describe('cuts', () => {
  const nim = read(
    fs.readFileSync(new URL('fs-cuts.bl', import.meta.url), 'utf8')
  ) as Value<'dict'>

  it('fall where blnim cuts the same bytes, into the same content', () => {
    for (const [name, data] of Object.entries(inputs)) {
      const theirs = nim.get(value.text(name)) as Value<'record'> | undefined
      expect(theirs, name).toBeDefined()
      const [content, chunks] = theirs!.fields
      const mine = contentOf(data)
      expect(print(digestOf(mine.content)), name).toBe(print(content!))
      expect(said(mine.chunks.map(digestOf)), name).toEqual(
        said((chunks as Value<'list'>).items)
      )
    }
  })

  it('cover the bytes in order, each 2048 to 65536 long but the last', () => {
    for (const [name, data] of Object.entries(inputs)) {
      const cs = [...cuts(data)]
      let next = 0
      cs.forEach(([a, b], i) => {
        expect(a, name).toBe(next)
        const n = b - a + 1
        expect(n, name).toBeLessThanOrEqual(65536)
        if (i < cs.length - 1) expect(n, name).toBeGreaterThanOrEqual(2048)
        next = b + 1
      })
      expect(next, name).toBe(data.length)
    }
  })

  it('change only around an edit', () => {
    const data = inputs['random.bin']!
    const edited = data.slice()
    edited[data.length >> 1] = edited[data.length >> 1]! ^ 0xff
    const before = new Set(
      said(
        [...cuts(data)].map(([a, b]) => digestOf(chunkOf(data.slice(a, b + 1))))
      )
    )
    const after = said(
      [...cuts(edited)].map(([a, b]) =>
        digestOf(chunkOf(edited.slice(a, b + 1)))
      )
    )
    expect(after.filter(d => !before.has(d)).length).toBeLessThanOrEqual(2)
  })
})

describe('content', () => {
  it('is the bytes atom up to 65536 bytes, a manifest past that', () => {
    const at = contentOf(inputs['inline-most.bin']!)
    expect(at.content.kind).toBe('bytes')
    expect(at.chunks).toEqual([])
    const past = contentOf(inputs['one-past.bin']!)
    expect(print((past.content as Value<'record'>).head)).toBe('chunks')
    expect(INLINE_MOST).toBe(65536)
  })

  it("a manifest names its chunks and says the file's size", () => {
    const data = inputs['random.bin']!
    const { content, chunks } = contentOf(data)
    const [size, ds] = (content as Value<'record'>).fields
    expect(size).toEqual(value.number(data.length))
    expect(said((ds as Value<'list'>).items)).toEqual(
      said(chunks.map(digestOf))
    )
  })

  it('has one digest for the same bytes', () => {
    const data = inputs['text.txt']!
    expect(print(digestOf(contentOf(data).content))).toBe(
      print(digestOf(contentOf(data.slice()).content))
    )
  })
})

describe('verifies', () => {
  const v = read('(chunk 0x0102)')

  it('holds for what a digest digests, and nothing else', () => {
    expect(verifies(digestOf(v), v)).toBe(true)
    expect(verifies(digestOf(v), read('(chunk 0x0103)'))).toBe(false)
    expect(
      verifies(
        digestOf(v),
        value.record(
          [value.sym('chunk'), value.bytes(new Uint8Array([1, 2]))],
          true
        )
      )
    ).toBe(false)
  })

  it('reads sha256 digests too', () => {
    const hash = createHash('sha256').update(encode(v)).digest('hex')
    expect(verifies(read(`(digest sha256 0x${hash})`), v)).toBe(true)
    expect(
      verifies(read(`(digest sha256 0x${hash})`), read('(chunk 0x0103)'))
    ).toBe(false)
  })

  it('reads a digest exactly', () => {
    const hash = print((digestOf(v) as Value<'record'>).fields[1]!)
    expect(verifies(read(`(digest blake2b ${hash})`), v)).toBe(true)
    for (const t of [
      '(digest blake2b)',
      `!(digest blake2b ${hash})`,
      `(digest blake2b ${hash} extra)`,
      `(digest md5 ${hash})`,
      `(digest "blake2b" ${hash})`,
      `(digest blake2b ${hash.slice(0, -2)})`,
      'nil',
    ])
      expect(verifies(read(t), v), t).toBe(false)
  })
})

describe('a tree', () => {
  const big = stored(inputs['random.bin']!)
  const small = stored(inputs['small.txt']!)
  const inner = tree([['hello.txt', fileEntry(small.d, 6, 0o644)]])
  const outer = tree([
    ['data.bin', fileEntry(big.d, inputs['random.bin']!.length, 0o644)],
    ['sub', dirEntry(digestOf(inner), 0o755)],
    ['latest', linkEntry('sub/hello.txt')],
  ])
  const all = [...big.held, ...small.held, inner, outer]
  const root = dirEntry(digestOf(outer), 0o755)

  it('lists its entries by name', () => {
    expect(listing(holding(all), root)!.map(([n]) => n)).toEqual([
      'sub',
      'latest',
      'data.bin',
    ])
    expect(said(listing(holding(all), outer)!.map(([, e]) => e))).toEqual(
      said(listing(holding(all), digestOf(outer))!.map(([, e]) => e))
    )
    expect(listing(holding([]), root)).toBeUndefined()
    expect(listing(holding([tree([])]), digestOf(tree([])))).toEqual([])
  })

  it('walks a path to an entry, and to nothing past a name it lacks', () => {
    const s = holding(all)
    const [hello] = walk(s, root, ['sub', 'hello.txt'])
    expect(print(named(hello!)!)).toBe(print(small.d))
    expect([...walk(s, root, ['sub', 'nope'])]).toEqual([])
    expect([...walk(s, root, ['latest', 'x'])]).toEqual([])
  })

  it("gives a file's bytes back, whole or from its chunks", () => {
    const s = holding(all)
    expect(bytesOf(s, small.d)).toEqual(inputs['small.txt'])
    expect(bytesOf(s, big.d)).toEqual(inputs['random.bin'])
  })

  it('says what it lacks, each digest once', () => {
    expect(missing(holding(all), digestOf(outer))).toEqual([])
    const lost = big.held[3]!
    const without = all.filter(v => v !== lost && v !== inner)
    expect(said(missing(holding(without), digestOf(outer)))).toEqual(
      said([digestOf(inner), digestOf(lost)])
    )
    expect(bytesOf(holding(without), big.d)).toBeUndefined()
    expect(said(missing(holding([]), digestOf(outer)))).toEqual(
      said([digestOf(outer)])
    )
  })

  it('passes over answers that are not what was asked', () => {
    const s = checked(liar([small.held[0]!, outer, inner]))
    expect(said(s.ask(digestOf(outer)))).toEqual(said([outer]))
    expect(bytesOf(checked(liar(all)), small.d)).toEqual(inputs['small.txt'])
  })

  it('reads text content as its UTF-8 bytes, and refuses a manifest that names something not a chunk or says the wrong size', () => {
    const t = value.text('héllo')
    expect(bytesOf(holding([t]), digestOf(t))).toEqual(
      new TextEncoder().encode('héllo')
    )
    const c = chunkOf(new Uint8Array([1, 2, 3]))
    const lying = read(`(chunks 4 [${print(digestOf(c))}])`)
    expect(() => bytesOf(holding([lying, c]), digestOf(lying))).toThrow(Refused)
    const notChunk = value.bytes(new Uint8Array([1, 2, 3]))
    const odd = read(`(chunks 3 [${print(digestOf(notChunk))}])`)
    expect(() => bytesOf(holding([odd, notChunk]), digestOf(odd))).toThrow(
      Refused
    )
    expect(missing(holding([odd, notChunk]), digestOf(odd))).toEqual([])
  })

  it('reads an entry with fields to spare, leaving them behind', () => {
    const wide = read(`(file ${print(small.d)} 6 420 (owner goose))`)
    expect(print(named(wide)!)).toBe(print(small.d))
    expect(named(read(`(file ${print(small.d)} 6)`))).toBeUndefined()
  })

  it('answers a digest once, however many sources hold it', () => {
    expect(
      said(checked(holding(all), holding(all)).ask(digestOf(outer)))
    ).toEqual(said([outer]))
  })

  it('walks below the top only through dir entries, never a bare digest', () => {
    const odd = tree([['sub', digestOf(inner)]])
    const s = holding([...all, odd])
    expect([...walk(s, digestOf(odd), ['sub'])].length).toBe(1)
    expect([...walk(s, digestOf(odd), ['sub', 'hello.txt'])]).toEqual([])
    expect([...walk(s, digestOf(inner), ['hello.txt'])].length).toBe(1)
  })

  it('reads any integer as size and mode, as fs.nim does', () => {
    const wide = read(`(dir ${print(digestOf(inner))} 99999999999999999999)`)
    expect(print(named(wide)!)).toBe(print(digestOf(inner)))
    expect(named(read(`(file ${print(small.d)} -1 -1)`))).toBeDefined()
  })

  it('keeps its digest under another name', () => {
    const renamed = tree([['elsewhere', dirEntry(digestOf(inner), 0o755)]])
    expect(print(listing(holding([renamed]), renamed)![0]![1])).toBe(
      print(listing(holding(all), outer)!.find(([n]) => n === 'sub')![1])
    )
  })
})
