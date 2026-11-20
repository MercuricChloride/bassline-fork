// @ts-check

// Walk CE bytes as a flat event stream: nil, atom, open, close. This is the
// shared primitive both the resumable decoder and any future async decoder
// sit on.
//
// Starvation throws {@link Starved} so a caller can stop and resume when more
// bytes arrive. Structural impossibilities a byte stream cannot resync past
// (a bad tag, a non-minimal length) throw {@link CodecError}. Deferred checks
// — UTF-8, integer canonicity, member order, an empty record, the depth
// limit — belong to validation on the built value, not here.

import {
  CodecError,
  END,
  MAX_VALUE_BYTES,
  isFrameKind,
  readHeader,
} from './header.js'
import { Starved } from './buffer.js'

export { CodecError }

/** @import { Kind } from './header.js' */
/** @import { ByteCursor } from './buffer.js' */

/**
 * One structural boundary crossing in a CE byte stream.
 * @typedef {{ t: 'nil', at: number, mark: boolean }
 *   | { t: 'atom', at: number, kind: Kind, mark: boolean, payloadAt: number, payloadLen: number }
 *   | { t: 'open', at: number, kind: Kind, mark: boolean }
 *   | { t: 'close', at: number }} WalkEvent
 */

/**
 * Yield one {@link WalkEvent} per value-boundary crossing under `cursor`,
 * advancing `cursor.pos` past each. On a partial trailing value the generator
 * throws {@link Starved} with `cursor.pos` left at that value's first byte, so
 * feeding a longer buffer and iterating again resumes cleanly.
 * @param {ByteCursor} cursor
 * @param {{ maxValueBytes?: number }} [opts]
 * @yields {WalkEvent}
 * @returns {Generator<WalkEvent, void>}
 */
export function* walkEvents(cursor, { maxValueBytes = MAX_VALUE_BYTES } = {}) {
  // the byte view is stable for this synchronous walk; the source only grows
  // between walks
  const buf = cursor.bytes
  while (cursor.pos < buf.length) {
    const at = cursor.pos
    const b = buf[at]

    if (b === END) {
      cursor.pos = at + 1
      yield { t: 'close', at }
      continue
    }

    const { kind, mark, lenBits } = readHeader(b)

    if (kind === 'nil') {
      cursor.pos = at + 1
      yield { t: 'nil', at, mark }
      continue
    }

    if (isFrameKind(kind)) {
      cursor.pos = at + 1
      yield { t: 'open', at, kind, mark }
      continue
    }

    // a scalar: resolve the length tier, then require the whole payload
    let len = lenBits
    let headerSize = 1
    if (lenBits === 7) {
      if (cursor.remaining < 2) throw new Starved()
      const l1 = buf[at + 1]
      if (l1 < 7) throw new CodecError('non-minimal length')
      if (l1 < 255) {
        len = l1
        headerSize = 2
      } else {
        if (cursor.remaining < 6) throw new Starved()
        len =
          ((buf[at + 2] * 256 + buf[at + 3]) * 256 + buf[at + 4]) * 256 +
          buf[at + 5]
        if (len < 255) throw new CodecError('non-minimal length')
        headerSize = 6
      }
    }

    if (len > maxValueBytes) {
      throw new CodecError('scalar payload exceeds the value-size limit')
    }
    const total = headerSize + len
    if (cursor.remaining < total) throw new Starved(total - cursor.remaining)

    cursor.pos = at + total
    yield {
      t: 'atom',
      at,
      kind,
      mark,
      payloadAt: at + headerSize,
      payloadLen: len,
    }
  }
}
