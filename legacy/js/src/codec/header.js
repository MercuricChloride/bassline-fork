// @ts-check

// The canonical-encoding header. This module is the sole authority for the
// tag numbering, the mark bit, END, and the length tiers. It walks bytes and
// knows nothing about any in-memory value type.
//
// Every value begins with one header byte: [tag:4][mark:1][len:3]. Tag 0 and
// 0xB..0xF are invalid, so a zeroed byte never decodes as a value. The three
// length bits carry a scalar's payload length (or 7 to signal an extension)
// and must be zero for nil and for frame headers.

export class CodecError extends Error {}

/** Kind name -> 4-bit tag. The single authority for the numbering. */
export const KIND = Object.freeze({
  nil: 0x1,
  number: 0x2,
  text: 0x3,
  symbol: 0x4,
  bytes: 0x5,
  list: 0x6,
  record: 0x7,
  dict: 0x8,
  set: 0x9,
})

/** @typedef {keyof typeof KIND} Kind */

/** Tag -> kind name. */
export const KIND_OF_TAG = Object.freeze(
  /** @type {Record<number, Kind>} */ (
    Object.fromEntries(Object.entries(KIND).map(([name, tag]) => [tag, name]))
  )
)

export const END = 0xa0
export const MARK_BIT = 0x08

/** The CE ceiling on a scalar payload: a uint32 length. */
export const MAX_PAYLOAD = 0xffffffff

/** Default nesting cap. Every decoder takes an override. */
export const MAX_DEPTH = 1024

/**
 * Default ceiling on what a decoder buffers toward one value: a scalar payload
 * this large, or an unclosed frame that reaches this many bytes, is refused
 * rather than held. A receiver draws its own line lower at its boundary.
 */
export const MAX_VALUE_BYTES = 100 * 1024 * 1024

const SCALAR_KINDS = new Set(['number', 'text', 'symbol', 'bytes'])
const FRAME_KINDS = new Set(['list', 'record', 'dict', 'set'])

/** @param {string} kind */
export const isScalarKind = kind => SCALAR_KINDS.has(kind)
/** @param {string} kind */
export const isFrameKind = kind => FRAME_KINDS.has(kind)

/**
 * Decode a header byte into its parts. Throws {@link CodecError} for a byte
 * that cannot begin a value: a bad tag, or a nil / frame header carrying
 * length bits. The 0xA0 END byte is not a header — test for it first.
 * @param {number} b
 * @returns {{ kind: Kind, mark: boolean, lenBits: number }}
 */
export function readHeader(b) {
  const tag = b >>> 4
  const kind = KIND_OF_TAG[tag]
  if (kind === undefined) {
    throw new CodecError('invalid tag 0x' + tag.toString(16))
  }
  const mark = (b & MARK_BIT) !== 0
  const lenBits = b & 0x07
  if (lenBits !== 0 && !isScalarKind(kind)) {
    throw new CodecError(kind + ' header carries length bits')
  }
  return { kind, mark, lenBits }
}

/**
 * The header byte for a value. `len` is a scalar's payload length; its low
 * three bits go inline, capped at 7 to signal an extension, and it must be 0
 * for nil and for frames.
 * @param {string} kind
 * @param {boolean} mark
 * @param {number} len
 */
export function headerByte(kind, mark, len) {
  const tag = KIND[/** @type {keyof typeof KIND} */ (kind)]
  if (tag === undefined) throw new CodecError('unknown kind ' + kind)
  const lo = isScalarKind(kind) ? Math.min(len, 7) : 0
  return (tag << 4) | (mark ? MARK_BIT : 0) | lo
}
