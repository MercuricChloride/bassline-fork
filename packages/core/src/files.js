/** @import {Value} from "./data.js" */
import { readFileSync, writeFileSync } from 'node:fs'
import { encode, decodeAll } from './data.js'
import { read } from './text/reader.js'
import { print } from './text/print.js'

const asList = values => (Array.isArray(values) ? values : [values])

/**
 * Write one value or an array of values to a binary file.
 * @param {string} path
 * @param {Value|Value[]} values
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
 * @param {string} path
 */
export function loadBinary(path) {
  return decodeAll(readFileSync(path))
}

/**
 * Write one value or an array of values to a text file.
 * @param {string} path
 * @param {Value|Value[]} values
 */
export function saveText(path, values) {
  writeFileSync(
    path,
    asList(values)
      .map(v => print(v))
      .join('\n\n') + '\n'
  )
}

/**
 * Parse a text file into its list of values.
 * @param {string} path
 */
export function loadText(path) {
  return read(readFileSync(path, 'utf8'))
}

// --- conversion between the two on-disk forms ---

/**
 * Convert a text file to binary.
 * @param {string} srcPath
 * @param {string} dstPath
 */
export function textToBinary(srcPath, dstPath) {
  saveBinary(dstPath, loadText(srcPath))
}

/**
 * Convert a binary file to text.
 * @param {string} srcPath
 * @param {string} dstPath
 */
export function binaryToText(srcPath, dstPath) {
  saveText(dstPath, loadBinary(srcPath))
}
