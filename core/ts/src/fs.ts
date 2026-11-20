// Files as values: content by digest, trees of names, and readings over a
// search from a digest to what it digests. A port of blnim's lib/fs.nim.
//
//   (digest blake2b H)        H blake2b-256 over the CE of what it names
//   BYTES                     a file of 65536 bytes or fewer, whole
//   (chunks SIZE [D …])       a larger file: its cuts in order, SIZE bytes in all
//   (chunk BYTES)             one cut
//   (tree {NAME: ENTRY …})    a directory, each NAME text
//   (file D SIZE MODE)  (dir D MODE)  (link TARGET)     its entries
//
// Cuts fall where the content says (blarc's gear hash), so the same bytes are
// cut the same way wherever they are added, an edit changes only the cuts
// around it, and a file has one digest whoever adds it. A name lives in the
// directory that holds it, so a tree under another name keeps its digest.
//
// What a digest names is found by asking a search. Any source will do, since
// an answer counts only when it is what the digest digests (`verifies`), and
// what a reading still lacks is a list of digests to go and ask for
// (`missing`), so a reader fed as answers arrive reads more each time.

import { blake2b } from '@noble/hashes/blake2.js'
import { sha256 } from '@noble/hashes/sha2.js'
import { encode } from './codec/index.ts'
import { Refused, Search, asSearch, type Asks } from './search.ts'
import { print } from './text/index.ts'
import { alt, empty, just } from './stream.ts'
import { eq, type Factory, type Value } from './types.ts'
import { value } from './values.ts'

/** The most bytes a file may have and still be its own bytes atom. */
export const INLINE_MOST = 65536
const MIN_CHUNK = 2 * 1024
const MAX_CHUNK = 64 * 1024
/** Cuts fall about every 2^13 bytes past the minimum. */
const CUT_BITS = 13

// blarc's gear table, fixed pseudo-random words (splitmix64), so every
// implementation cuts in the same places. Each word is held as two halves,
// since the rolling hash is 64 bits wide.
const GEAR_HI = new Uint32Array(256)
const GEAR_LO = new Uint32Array(256)
{
  const m64 = (1n << 64n) - 1n
  let x = 0n
  for (let i = 0; i < 256; i++) {
    x = (x + 0x9e3779b97f4a7c15n) & m64
    let z = x
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & m64
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & m64
    z ^= z >> 31n
    GEAR_HI[i] = Number(z >> 32n)
    GEAR_LO[i] = Number(z & 0xffffffffn)
  }
}

/**
 * The first and last index of each chunk of `data`: a cut falls where the
 * gear hash of the bytes since the last cut has its top 13 bits clear, no
 * sooner than 2048 bytes in and no later than 65536.
 */
export function* cuts(data: Uint8Array): Generator<[number, number]> {
  let start = 0
  let hi = 0
  let lo = 0
  for (let i = 0; i < data.length; i++) {
    const b = data[i]!
    // h = (h shl 1) + Gear[b], modulo 2^64
    hi = ((hi << 1) | (lo >>> 31)) >>> 0
    const sum = ((lo << 1) >>> 0) + GEAR_LO[b]!
    lo = sum >>> 0
    hi = (hi + GEAR_HI[b]! + (sum > 0xffffffff ? 1 : 0)) >>> 0
    const n = i - start + 1
    if (n >= MAX_CHUNK || (n >= MIN_CHUNK && hi >>> (32 - CUT_BITS) === 0)) {
      yield [start, i]
      start = i + 1
      hi = 0
      lo = 0
    }
  }
  if (start < data.length) yield [start, data.length - 1]
}

const HASHES: Record<string, (b: Uint8Array) => Uint8Array> = {
  blake2b: b => blake2b(b, { dkLen: 32 }),
  sha256: b => sha256(b),
}

const sameBytes = (a: Uint8Array, b: Uint8Array) =>
  a.length === b.length && a.every((x, i) => x === b[i])

const hex = (b: Uint8Array) =>
  Array.from(b, x => x.toString(16).padStart(2, '0')).join('')

/** An entry of a tree, as read. */
export type Entry =
  | {
      kind: 'file'
      digest: Value
      size: number | bigint
      mode: number | bigint
    }
  | { kind: 'dir'; digest: Value; mode: number | bigint }
  | { kind: 'link'; target: string }

/** The fs dialect, building values through the factory `f`. */
export function files(f: Factory = value) {
  const h = {
    digest: f.sym('digest'),
    blake2b: f.sym('blake2b'),
    chunks: f.sym('chunks'),
    chunk: f.sym('chunk'),
    tree: f.sym('tree'),
    file: f.sym('file'),
    dir: f.sym('dir'),
    link: f.sym('link'),
  } as const

  /**
   * `v`'s fields when it is an unmarked record under `head` with `width`
   * items, head and all, or more unless `exact`: what a reading doesn't
   * describe it leaves behind.
   */
  function fieldsOf(
    v: Value,
    head: Value,
    width: number,
    exact = false
  ): Value[] | undefined {
    if (v.kind !== 'record' || v.mark) return undefined
    if (exact ? v.length !== width : v.length < width) return undefined
    return eq(v.head, head) ? v.fields : undefined
  }

  /** An unmarked integer, or undefined. */
  function integer(v: Value | undefined): number | bigint | undefined {
    return v?.kind === 'number' && !v.mark ? v.payload : undefined
  }

  /** (digest blake2b H), H blake2b-256 over `v`'s CE. */
  function digestOf(v: Value): Value {
    return f.record([
      h.digest,
      h.blake2b,
      f.bytes(HASHES['blake2b']!(encode(v))),
    ])
  }

  /** The algorithm and hash `d` says, read exactly: (digest blake2b|sha256 HASH), HASH 32 bytes. */
  function readDigest(d: Value) {
    const [algo, hash] = fieldsOf(d, h.digest, 3, true) ?? []
    if (
      algo?.kind !== 'symbol' ||
      algo.mark ||
      !Object.hasOwn(HASHES, algo.payload)
    )
      return undefined
    if (hash?.kind !== 'bytes' || hash.mark || hash.length !== 32)
      return undefined
    return { hashing: HASHES[algo.payload]!, hash: hash.payload }
  }

  /** Whether `d` is the digest of `v`, by whichever algorithm it names. */
  function verifies(d: Value, v: Value): boolean {
    const r = readDigest(d)
    return r !== undefined && sameBytes(r.hashing(encode(v)), r.hash)
  }

  /**
   * The content value `data` is, and the chunks it names: its bytes atom when
   * it has 65536 bytes or fewer and no chunks, otherwise (chunks SIZE [D …])
   * over its cuts, each D the digest of one (chunk BYTES).
   */
  function contentOf(data: Uint8Array): { content: Value; chunks: Value[] } {
    if (data.length <= INLINE_MOST)
      return { content: f.bytes(data.slice()), chunks: [] }
    const chunks = [...cuts(data)].map(([a, b]) =>
      f.record([h.chunk, f.bytes(data.slice(a, b + 1))])
    )
    const content = f.record([
      h.chunks,
      f.number(data.length),
      f.list(chunks.map(digestOf)),
    ])
    return { content, chunks }
  }

  const fileEntry = (d: Value, size: number, mode: number) =>
    f.record([h.file, d, f.number(size), f.number(mode)])
  const dirEntry = (d: Value, mode: number) =>
    f.record([h.dir, d, f.number(mode)])
  const linkEntry = (target: string) => f.record([h.link, f.text(target)])

  /** (tree {NAME: ENTRY …}); a name given twice keeps the last entry given. */
  function tree(entries: Iterable<[string, Value]>): Value {
    const named = new Map(entries)
    return f.record([
      h.tree,
      f.dict([...named].map(([n, e]) => [f.text(n), e] as [Value, Value])),
    ])
  }

  /** An entry read, or undefined for a value that isn't one. */
  function readEntry(v: Value): Entry | undefined {
    if (v.kind !== 'record' || v.mark) return undefined
    const file = fieldsOf(v, h.file, 4)
    if (file) {
      const [d, size, mode] = file
      const s = integer(size)
      const m = integer(mode)
      return readDigest(d!) && s !== undefined && m !== undefined
        ? { kind: 'file', digest: d!, size: s, mode: m }
        : undefined
    }
    const dir = fieldsOf(v, h.dir, 3)
    if (dir) {
      const [d, mode] = dir
      const m = integer(mode)
      return readDigest(d!) && m !== undefined
        ? { kind: 'dir', digest: d!, mode: m }
        : undefined
    }
    const [target] = fieldsOf(v, h.link, 2) ?? []
    return target?.kind === 'text' && !target.mark
      ? { kind: 'link', target: target.payload }
      : undefined
  }

  /** The digest an entry names: a file's content, a directory's tree. */
  function named(entry: Value): Value | undefined {
    const e = readEntry(entry)
    return e && e.kind !== 'link' ? e.digest : undefined
  }

  /** A tree's entries by name, in canonical order, or undefined for anything not a tree. */
  function readTree(v: Value): [string, Value][] | undefined {
    const [d] = fieldsOf(v, h.tree, 2) ?? []
    if (d?.kind !== 'dict' || d.mark) return undefined
    const out: [string, Value][] = []
    for (const [n, e] of d.entries()) {
      if (n.kind !== 'text' || n.mark) return undefined
      out.push([n.payload, e])
    }
    return out
  }

  /** A manifest's size and chunk digests, or undefined for anything not one. */
  function readManifest(v: Value) {
    const [size, ds] = fieldsOf(v, h.chunks, 3, true) ?? []
    const s = integer(size)
    if (s === undefined || ds?.kind !== 'list' || ds.mark) return undefined
    return ds.items.every(d => readDigest(d))
      ? { size: s, digests: ds.items }
      : undefined
  }

  /** A chunk's bytes, or undefined for anything not one. */
  function readChunk(v: Value): Uint8Array | undefined {
    const [b] = fieldsOf(v, h.chunk, 2, true) ?? []
    return b?.kind === 'bytes' && !b.mark ? b.payload : undefined
  }

  /**
   * The sources' answers to a digest taking turns, passing over every answer
   * the digest isn't of. Every answer that verifies is the one value the
   * digest is of, so it is answered once however many sources hold it.
   */
  function checked(...sources: Asks<Value, Value>[]): Search<Value, Value> {
    const ss = sources.map(asSearch)
    return new Search<Value, Value>(function* (d) {
      if (!readDigest(d)) return
      for (const v of alt(...ss.map(s => s.ask(d))))
        if (verifies(d, v)) return yield v
    })
  }

  /** A search from a digest to whichever of `values` it digests. */
  function holding(values: Iterable<Value>): Search<Value, Value> {
    const byHash = new Map<string, Value[]>()
    for (const v of values) {
      for (const hash of Object.values(HASHES)) {
        const k = hex(hash(encode(v)))
        byHash.set(k, [...(byHash.get(k) ?? []), v])
      }
    }
    return new Search<Value, Value>(d => {
      const r = readDigest(d)
      return r
        ? (byHash.get(hex(r.hash)) ?? []).filter(v => verifies(d, v))
        : []
    })
  }

  /**
   * The digests under `d` that `s` has no checked answer for, each once,
   * `d` first: a file's chunks, a tree's entries and everything under them.
   */
  function missing(s: Asks<Value, Value>, d: Value): Value[] {
    const c = checked(s)
    const seen = new Set<string>()
    const out: Value[] = []
    const go = (d: Value) => {
      const k = hex(encode(d))
      if (seen.has(k)) return
      seen.add(k)
      const v = c.first(d)
      if (v === undefined) return void out.push(d)
      for (const under of readManifest(v)?.digests ?? []) go(under)
      for (const [, e] of readTree(v) ?? []) {
        const n = named(e)
        if (n) go(n)
      }
    }
    go(d)
    return out
  }

  /**
   * The bytes of the content `d` names, or undefined while some part of it
   * isn't answered. Text content, as the artifact dialect allows, is its
   * UTF-8 bytes. Refuses a manifest naming something not a chunk, or whose
   * chunks don't hold the size it says.
   */
  function bytesOf(s: Asks<Value, Value>, d: Value): Uint8Array | undefined {
    const c = checked(s)
    const v = c.first(d)
    if (v === undefined) return undefined
    if (v.kind === 'bytes' && !v.mark) return v.payload
    if (v.kind === 'text' && !v.mark) return new TextEncoder().encode(v.payload)
    const m = readManifest(v)
    if (!m) return undefined
    const parts: Uint8Array[] = []
    for (const cd of m.digests) {
      const chunk = c.first(cd)
      if (chunk === undefined) return undefined
      const b = readChunk(chunk)
      if (b === undefined)
        throw new Refused(
          `${print(d)} names ${print(cd)}, which is not a chunk`
        )
      parts.push(b)
    }
    const size = parts.reduce((n, b) => n + b.length, 0)
    if (BigInt(size) !== BigInt(m.size))
      throw new Refused(
        `${print(d)} says ${m.size} bytes and its chunks hold ${size}`
      )
    const out = new Uint8Array(size)
    parts.reduce((at, b) => (out.set(b, at), at + b.length), 0)
    return out
  }

  /** The tree a (dir D MODE) entry names. */
  function dirTree(s: Asks<Value, Value>, entry: Value) {
    const e = readEntry(entry)
    const v = e?.kind === 'dir' ? checked(s).first(e.digest) : undefined
    return v && readTree(v)
  }

  /** The tree `t` is, or names as a digest or a (dir D MODE) entry. */
  function treeOf(
    s: Asks<Value, Value>,
    t: Value
  ): [string, Value][] | undefined {
    if (!readDigest(t)) return readTree(t) ?? dirTree(s, t)
    const v = checked(s).first(t)
    return v && readTree(v)
  }

  /**
   * A directory's names and their entries, in canonical order, or undefined
   * while `s` doesn't answer the tree: `t` the tree, its digest, or a dir entry.
   */
  function listing(
    s: Asks<Value, Value>,
    t: Value
  ): [string, Value][] | undefined {
    return treeOf(s, t)
  }

  /**
   * The entries `path` names from `t`, one name a step: `t` a tree, its
   * digest or a dir entry, and below it only the dir entries a tree holds.
   */
  function walk(
    s: Asks<Value, Value>,
    t: Value,
    path: readonly string[]
  ): Iterable<Value> {
    const step = (
      tree: [string, Value][] | undefined,
      path: readonly string[]
    ): Iterable<Value> => {
      const [name, ...rest] = path
      const e = tree?.find(([n]) => n === name)?.[1]
      if (e === undefined) return empty()
      return rest.length === 0 ? just(e) : step(dirTree(s, e), rest)
    }
    return path.length === 0 ? just(t) : step(treeOf(s, t), path)
  }

  return {
    digestOf,
    verifies,
    contentOf,
    fileEntry,
    dirEntry,
    linkEntry,
    tree,
    readEntry,
    readTree,
    named,
    checked,
    holding,
    missing,
    bytesOf,
    listing,
    walk,
  }
}
