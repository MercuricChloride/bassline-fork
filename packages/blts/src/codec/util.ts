import { tagToKind, TAGS, type ValueKind } from '../types.ts'

/**
 * Why a decoder refused. The first eleven are the corpus's closed list,
 * lifted from "what a decoder must reject"; the rest are this decoder's own
 * limits and the one-value reading's.
 */
export type Reason =
  | 'invalid-tag'
  | 'end-with-bits'
  | 'end-at-top'
  | 'length-bits'
  | 'non-minimal-length'
  | 'bad-integer'
  | 'bad-utf8'
  | 'empty-record'
  | 'stranded-key'
  | 'out-of-order'
  | 'duplicate'
  | 'max-depth'
  | 'max-value-bytes'
  | 'no-value'
  | 'several-values'

/** A refusal: the bytes break a rule, and more bytes cannot mend them. */
export class CodecError extends Error {
  readonly reason: Reason
  constructor(reason: Reason, message: string = reason) {
    super(message)
    this.reason = reason
  }
}

/** The input ran out inside a value, having broken no rule. */
export class Incomplete extends Error {}

export const MAX_VALUE_BYTES = 100 * 1024 * 1024
export const END = 0xa0
export const MARK_BIT = 0x08
/** The CE ceiling on a scalar payload. */
export const MAX_PAYLOAD = 0xffffffff
/** The nesting limit for values */
export const MAX_DEPTH = 1024

/**
 * The parts of a byte that begins a value. END is not one: at the top
 * level it is refused here, and inside a frame the decoder takes it first.
 */
export function readHeader(b: number) {
  if (b >>> 4 === END >>> 4) {
    throw new CodecError(b === END ? 'end-at-top' : 'end-with-bits')
  }
  const kind = tagToKind(b >>> 4)
  if (kind === undefined) {
    throw new CodecError(
      'invalid-tag',
      'invalid tag 0x' + (b >>> 4).toString(16)
    )
  }
  const mark = (b & MARK_BIT) !== 0
  const lenBits = b & 0x07
  switch (kind) {
    case 'nil':
    case 'list':
    case 'record':
    case 'dict':
    case 'set':
      if (lenBits !== 0) {
        throw new CodecError(
          'length-bits',
          kind + ' header should carry no length bits'
        )
      }
  }
  return { kind, mark, lenBits } as const
}

/** The header byte; `len` is a scalar's payload length, 0 otherwise. */
export function writeHeader(kind: ValueKind, mark: boolean, len: number) {
  return (TAGS[kind] << 4) | (mark ? MARK_BIT : 0) | Math.min(len, 7)
}

const FATAL_UTF8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true })

export const validate = {
  /**
   * Implements the regex: /^(0|-?[1-9][0-9]*)$/
   * over raw bytes
   */
  number(bytes: Uint8Array) {
    const n = bytes.length
    if (n === 0) return false
    let i = bytes[0] === 0x2d /* - */ ? 1 : 0
    if (i === n) return false // a bare "-"
    if (bytes[i] === 0x30 /* 0 */) {
      return i === 0 && n === 1 // "0" is the only spelling that starts with zero
    }
    for (; i < n; i++) {
      if (bytes[i]! < 0x30 || bytes[i]! > 0x39) return false
    }
    return true
  },
  text(bytes: Uint8Array) {
    try {
      FATAL_UTF8.decode(bytes)
      return true
    } catch {
      return false
    }
  },
} as const

/**
 * The integer a canonical spelling names: a number when it is a safe
 * integer, otherwise a bigint.
 */
export function integer(spelling: string): number | bigint {
  const n = Number(spelling)
  return Number.isSafeInteger(n) ? n : BigInt(spelling)
}

/** Ill-formed UTF-8 throws; a leading BOM is kept, not stripped. */
export const decodeUtf8 = (bytes: Uint8Array) => FATAL_UTF8.decode(bytes)

/**
 * Bytewise comparison then shorter-first on a shared prefix.
 * This is the order CE bytes impose on whole encodings since
 * the frame end (0xA0) outranks any header byte the longer frame
 * continues with
 */
export function compareEncoded(a: Uint8Array, b: Uint8Array) {
  const n = Math.min(a.length, b.length)
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) return a[i]! - b[i]!
  }
  return a.length - b.length
}

/**
 * Shortlex first, then bytewise. Because scalars are length prefixed
 * in the encoding
 */
export function compareScalar(a: Uint8Array, b: Uint8Array) {
  if (a.length !== b.length) return a.length - b.length
  return compareEncoded(a, b)
}
