import { describe, it, expect, afterAll } from 'vitest'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import * as F from '../src/files.js'
import { fresh, eq } from '../src/data.js'
const { bytes, int, float, string, symbol, record, set } = fresh

const dir = mkdtempSync(join(tmpdir(), 'bassline-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
const p = name => join(dir, name)
const eqAll = (xs, ys) =>
  xs.length === ys.length && xs.every((x, i) => eq(x, ys[i]))

const sampleDoc = [
  int(1n),
  string('two'),
  record([symbol('point'), float(3.5), int(4n).copy(true)]),
  set([bytes(Uint8Array.of(0xa0)), bytes(Uint8Array.of(0x80))]),
]

describe('binary files', () => {
  it('round-trips a multi-value document', () => {
    F.saveBinary(p('doc.bce'), sampleDoc)
    expect(eqAll(F.loadBinary(p('doc.bce')), sampleDoc)).toBe(true)
  })

  it('accepts a single value and an empty document', () => {
    F.saveBinary(p('one.bce'), int(7n))
    expect(eqAll(F.loadBinary(p('one.bce')), [int(7n)])).toBe(true)
    F.saveBinary(p('empty.bce'), [])
    expect(F.loadBinary(p('empty.bce'))).toEqual([])
  })
})

describe('text files', () => {
  it('round-trips a multi-value document', () => {
    F.saveText(p('doc.blt'), sampleDoc)
    expect(eqAll(F.loadText(p('doc.blt')), sampleDoc)).toBe(true)
  })
})

describe('conversion', () => {
  it('text -> binary -> text preserves the document', () => {
    F.saveText(p('a.blt'), sampleDoc)
    F.textToBinary(p('a.blt'), p('a.bce'))
    expect(eqAll(F.loadBinary(p('a.bce')), sampleDoc)).toBe(true)
    F.binaryToText(p('a.bce'), p('b.blt'))
    expect(eqAll(F.loadText(p('b.blt')), sampleDoc)).toBe(true)
  })
})
