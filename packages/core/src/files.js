/** @import {Value} from "./data.js" */
import { readFileSync, writeFileSync } from 'node:fs'
import { encode, decodeAll } from './data.js'
import { read } from './text/reader.js'
import { print } from './text/print.js'

// The two on-disk spellings of the same values.
export const BINARY_EXT = '.blb'
export const TEXT_EXT = '.blt'

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

// --- extension-directed and self-detecting forms ---

/**
 * Write values to either on-disk form: text when the path ends in .blt
 * or {text} says so, binary otherwise.
 * @param {string} path
 * @param {Value|Value[]} values
 * @param {{text?: boolean}} [opts]
 */
export function saveValues(path, values, opts = {}) {
  const text = opts.text ?? path.endsWith(TEXT_EXT)
  if (text) saveText(path, values)
  else saveBinary(path, values)
}

/**
 * Parse bytes that are either binary CE or utf-8 text. The extension
 * decides when known; otherwise binary is tried first (its decoder is
 * strict), then text.
 * @param {Uint8Array} buf
 * @param {{path?: string, text?: boolean, binary?: boolean}} [opts]
 * @returns {Value[]}
 */
export function parseValues(buf, opts = {}) {
  const asText = () =>
    read(new TextDecoder('utf-8', { fatal: true }).decode(buf))
  const asBinary = () => decodeAll(buf)
  if (opts.text) return asText()
  if (opts.binary) return asBinary()
  if (opts.path?.endsWith(TEXT_EXT)) return asText()
  if (opts.path?.endsWith(BINARY_EXT)) return asBinary()
  try {
    return asBinary()
  } catch {
    return asText()
  }
}

/**
 * Load a file in either form, detected by extension or content.
 * @param {string} path
 * @param {{text?: boolean, binary?: boolean}} [opts]
 * @returns {Value[]}
 */
export function loadValues(path, opts = {}) {
  return parseValues(readFileSync(path), { ...opts, path })
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
