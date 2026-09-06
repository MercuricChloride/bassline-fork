// @ts-check

// Payload-level validity and the two byte orderings the encoding imposes.
// Pure functions over byte ranges; no header knowledge.

const FATAL_UTF8 = new TextDecoder('utf-8', { fatal: true })

/**
 * A canonical integer spelling as a string: from the data model — no leading
 * zero, no `-0`, no `+`, no bare `-`. The reader tests token strings against
 * this; {@link isCanonicalInt} is the same rule over bytes.
 */
export const CANONICAL_INT = /^(0|-?[1-9][0-9]*)$/

/**
 * Whether `bytes` is a canonical integer spelling: an optional leading `-`,
 * then digits with no leading zero, and never `-0` or a bare `-`. The
 * byte-level twin of {@link CANONICAL_INT}, allocating nothing.
 * @param {Uint8Array} bytes
 */
export function isCanonicalInt(bytes) {
  const n = bytes.length
  if (n === 0) return false
  let i = bytes[0] === 0x2d /* - */ ? 1 : 0
  if (i === n) return false // a bare "-"
  if (bytes[i] === 0x30 /* 0 */) {
    return i === 0 && n === 1 // "0" is the only spelling that starts with zero
  }
  for (; i < n; i++) {
    if (bytes[i] < 0x30 || bytes[i] > 0x39) return false
  }
  return true
}

/**
 * Whether `bytes` is well-formed UTF-8: no overlong forms, no surrogate code
 * points, no truncated sequences.
 * @param {Uint8Array} bytes
 */
export function isWellFormedUtf8(bytes) {
  try {
    FATAL_UTF8.decode(bytes)
    return true
  } catch {
    return false
  }
}

/**
 * UTF-8 bytes to a string, throwing on ill-formed input.
 * @param {Uint8Array} bytes
 */
export const decodeUtf8 = bytes => FATAL_UTF8.decode(bytes)

/**
 * Bytewise, then shorter-first on a shared prefix. This is the order CE bytes
 * impose between two whole encodings (a shorter frame's END, 0xA0, outranks
 * any header byte the longer frame continues with).
 * @param {Uint8Array} a
 * @param {Uint8Array} b
 */
export function compareBytes(a, b) {
  const n = Math.min(a.length, b.length)
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) return a[i] - b[i]
  }
  return a.length - b.length
}

/**
 * Shortlex: shorter first, then bytewise. This is the order a scalar payload
 * imposes, since a scalar's length precedes its bytes in the encoding.
 * @param {Uint8Array} a
 * @param {Uint8Array} b
 */
export function compareShortlex(a, b) {
  if (a.length !== b.length) return a.length - b.length
  return compareBytes(a, b) // equal lengths: purely bytewise from here
}
