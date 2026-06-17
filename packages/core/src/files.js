// Read and write Bassline values to files, in either the canonical binary
// encoding or the textual syntax. Both forms hold a document — zero or more
// values. Node-only (uses the filesystem).

import { readFileSync, writeFileSync } from 'node:fs'
import { encode, decodeAll } from './data.js'
import { parse } from './text/parser.js'
import { print } from './text/print.js'

const asList = values => (Array.isArray(values) ? values : [values])

/**
 * Write one value or an array of values to a binary file.
 * @param path
 * @param values
 */
export function saveBinary(path, values) {
  const parts = asList(values).map(encode)
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let off = 0
  for (const p of parts) {
    out.set(p, off)
    off += p.length
  }
  writeFileSync(path, out)
}

/**
 * Decode the sequence of values stored in a binary file.
 * @param path
 */
export function loadBinary(path) {
  return decodeAll(readFileSync(path))
}

// --- text: the .blt syntax, a document of zero or more values ---

/**
 * Write one value or an array of values to a text file.
 * @param path
 * @param values
 */
export function saveText(path, values) {
  writeFileSync(path, asList(values).map(print).join('\n\n') + '\n')
}

/**
 * Parse a text file into its list of values.
 * @param path
 */
export function loadText(path) {
  return parse(readFileSync(path, 'utf8'))
}

// --- conversion between the two on-disk forms ---

/**
 * Convert a text file to binary.
 * @param srcPath
 * @param dstPath
 */
export function textToBinary(srcPath, dstPath) {
  saveBinary(dstPath, loadText(srcPath))
}

/**
 * Convert a binary file to text.
 * @param srcPath
 * @param dstPath
 */
export function binaryToText(srcPath, dstPath) {
  saveText(dstPath, loadBinary(srcPath))
}
