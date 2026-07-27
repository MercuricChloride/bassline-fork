import { describe, it, expect, afterAll } from 'vitest'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import * as F from '../src/files.js'
import {
  eq,
  withMark,
  bytes,
  int,
  string,
  symbol,
  record,
  set,
} from '../src/data.js'

const dir = mkdtempSync(join(tmpdir(), 'bassline-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
const p = name => join(dir, name)
const eqAll = (xs, ys) =>
  xs.length === ys.length && xs.every((x, i) => eq(x, ys[i]))

const sampleDoc = [
  int(1n),
  string('two'),
  record([symbol('point'), int(3n), withMark(int(4n), true)]),
  set([bytes(Uint8Array.of(0xa0)), bytes(Uint8Array.of(0x80))]),
]

describe('binary files (.blt)', () => {
  it('round-trips a multi-value document', () => {
    F.saveBinary(p('doc.blt'), sampleDoc)
    expect(eqAll(F.loadBinary(p('doc.blt')), sampleDoc)).toBe(true)
  })

  it('accepts a single value and an empty document', () => {
    F.saveBinary(p('one.blt'), int(7n))
    expect(eqAll(F.loadBinary(p('one.blt')), [int(7n)])).toBe(true)
    F.saveBinary(p('empty.blt'), [])
    expect(F.loadBinary(p('empty.blt'))).toEqual([])
  })
})

describe('text files (.bl)', () => {
  it('round-trips a multi-value document', () => {
    F.saveText(p('doc.bl'), sampleDoc)
    expect(eqAll(F.loadText(p('doc.bl')), sampleDoc)).toBe(true)
  })

  it('rejects ill-formed UTF-8 instead of substituting', () => {
    writeFileSync(p('bad.bl'), Uint8Array.of(0x28, 0x66, 0x20, 0xff, 0x29))
    expect(() => F.loadText(p('bad.bl'))).toThrow()
  })
})

describe('extension-directed forms', () => {
  it('saveValues and loadValues pick the form from the suffix', () => {
    F.saveValues(p('by-ext.bl'), sampleDoc)
    expect(eqAll(F.loadValues(p('by-ext.bl')), sampleDoc)).toBe(true)
    F.saveValues(p('by-ext.blt'), sampleDoc)
    expect(eqAll(F.loadValues(p('by-ext.blt')), sampleDoc)).toBe(true)
  })
})

describe('conversion', () => {
  it('text -> binary -> text preserves the document', () => {
    F.saveText(p('a.bl'), sampleDoc)
    F.textToBinary(p('a.bl'), p('a.blt'))
    expect(eqAll(F.loadBinary(p('a.blt')), sampleDoc)).toBe(true)
    F.binaryToText(p('a.blt'), p('b.bl'))
    expect(eqAll(F.loadText(p('b.bl')), sampleDoc)).toBe(true)
  })
})
