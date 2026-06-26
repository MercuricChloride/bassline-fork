//@ts-check
// Find value boundaries in a bassline binary stream.
//
// Each value is fixed-size (nil/false/true = 1 byte, float = 9) or
// `descriptor + varint(byteLen) + payload`. For frames the varint is the byte
// length of the payload, so a value's size is known from its header without
// recursing. Scanning is O(1) per value.

import {
  NIL_PREFIX,
  FALSE_PREFIX,
  TRUE_PREFIX,
  INT_PREFIX,
  FLOAT_PREFIX,
  STRING_PREFIX,
  SYMBOL_PREFIX,
  BYTES_PREFIX,
  LIST_PREFIX,
  DICT_PREFIX,
  RECORD_PREFIX,
  SET_PREFIX,
  TAG_MASK,
} from '@bassline/core/data'

/** Returned when the buffer doesn't yet hold a value's header (descriptor + varint). */
export const NEED_MORE = Symbol('NEED_MORE')

const FLOAT_BYTES = 8

/** A length varint past this many bytes is garbage; reject rather than buffer forever. */
const MAX_VARINT_BYTES = 10

/**
 * Read an unsigned LEB128 varint at `offset`, returning {@link NEED_MORE} on
 * underflow instead of throwing. Minimality isn't checked here; core `decode()`
 * re-validates the sliced value.
 * @param {Uint8Array} bytes
 * @param {number} offset
 * @returns {{ value: number, size: number } | typeof NEED_MORE}
 */
export function peekVarint(bytes, offset) {
  let result = 0
  let mul = 1
  let i = offset
  while (true) {
    if (i >= bytes.length) return NEED_MORE
    if (i - offset >= MAX_VARINT_BYTES) {
      throw new Error('varint too long')
    }
    const b = bytes[i++]
    result += (b & 0x7f) * mul
    if ((b & 0x80) === 0) return { value: result, size: i - offset }
    mul *= 128
  }
}

/**
 * Byte length of the value at `offset` once its header is readable, else
 * {@link NEED_MORE}. The payload need not be present yet, so the caller must
 * check `offset + len <= bytes.length` before slicing. Returning the size from
 * the header alone lets the decoder reject an over-large value before buffering
 * its body. Throws on a descriptor that can't begin a value (tag `0x0` or `> 0xc`).
 * @param {Uint8Array} bytes
 * @param {number} [offset]
 * @returns {number | typeof NEED_MORE}
 */
export function scanValue(bytes, offset = 0) {
  if (offset >= bytes.length) return NEED_MORE
  const tag = bytes[offset] & TAG_MASK

  switch (tag) {
    case NIL_PREFIX:
    case FALSE_PREFIX:
    case TRUE_PREFIX:
      return 1

    case FLOAT_PREFIX:
      return 1 + FLOAT_BYTES

    case INT_PREFIX:
    case STRING_PREFIX:
    case SYMBOL_PREFIX:
    case BYTES_PREFIX:
    case LIST_PREFIX:
    case DICT_PREFIX:
    case RECORD_PREFIX:
    case SET_PREFIX: {
      const v = peekVarint(bytes, offset + 1)
      if (v === NEED_MORE) return NEED_MORE
      return 1 + v.size + v.value
    }

    default:
      throw new Error(
        'cannot frame value: bad descriptor 0x' +
          bytes[offset].toString(16).padStart(2, '0')
      )
  }
}
