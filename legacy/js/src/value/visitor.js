// @ts-check

/**
 * @import {
 *   Value, Atom, Frame,
 *   BNil, BInt, BText, BSym, BBytes,
 *   BList, BRecord, BDict, BSet,
 * } from './value.js'
 */

/**
 * Double-dispatch base for structural passes over a value. A subclass
 * overrides only the hooks it needs; the rest fall through
 * visitX -> visitAtom / visitFrame -> visitValue.
 *
 * `v.accept(visitor)` is the one place — spread one line per class — that
 * switches on kind. Binary relations (compare, similar, prefixes) are not
 * visitors: they match one value against another and stay plain functions.
 */
export class Visitor {
  /* eslint-disable jsdoc/require-returns-check -- refusing fallback; a real visitor overrides what it handles */
  /**
   * The fallback when a subclass overrides nothing more specific.
   * @param {Value} v
   * @returns {unknown}
   */
  visitValue(v) {
    throw new Error('unhandled ' + v.kind)
  }
  /* eslint-enable jsdoc/require-returns-check */
  /**
   * @param {Atom} v
   * @returns {unknown}
   */
  visitAtom(v) {
    return this.visitValue(v)
  }
  /**
   * @param {Frame} v
   * @returns {unknown}
   */
  visitFrame(v) {
    return this.visitValue(v)
  }
  /** @param {BNil} v */
  visitNil(v) {
    return this.visitAtom(v)
  }
  /** @param {BInt} v */
  visitInt(v) {
    return this.visitAtom(v)
  }
  /** @param {BText} v */
  visitText(v) {
    return this.visitAtom(v)
  }
  /** @param {BSym} v */
  visitSym(v) {
    return this.visitAtom(v)
  }
  /** @param {BBytes} v */
  visitBytes(v) {
    return this.visitAtom(v)
  }
  /** @param {BList} v */
  visitList(v) {
    return this.visitFrame(v)
  }
  /** @param {BRecord} v */
  visitRecord(v) {
    return this.visitFrame(v)
  }
  /** @param {BDict} v */
  visitDict(v) {
    return this.visitFrame(v)
  }
  /** @param {BSet} v */
  visitSet(v) {
    return this.visitFrame(v)
  }
}

/**
 * Depth-first pre-order walk: yield a value, then its constituents (dict
 * constituents are key, value, key, value, ...). Iterative on an explicit
 * stack, so a value deeper than the call stack still walks.
 * @param {Value} root
 * @yields {Value}
 * @returns {Generator<Value, void>}
 */
export function* walk(root) {
  /** @type {Iterator<Value>[]} */
  const stack = [[root][Symbol.iterator]()]
  while (stack.length) {
    const { value, done } = stack[stack.length - 1].next()
    if (done) {
      stack.pop()
      continue
    }
    yield value
    if (value.isFrame()) stack.push(value.members()[Symbol.iterator]())
  }
}

/**
 * Drive a value as open / atom / close events, iteratively. The encoder and
 * any other whole-tree pass that must survive deep values use this rather
 * than recursion through accept().
 * @param {Value} root
 * @param {{
 *   atom: (v: Value) => void,
 *   open: (v: Value) => void,
 *   close: (v: Value) => void,
 * }} handlers
 */
export function fold(root, handlers) {
  /** @type {Array<{ v: Value, it: Iterator<Value> | null }>} */
  const stack = [{ v: root, it: null }]
  while (stack.length) {
    const top = stack[stack.length - 1]
    if (top.it === null) {
      const frame = top.v
      if (frame.isFrame()) {
        handlers.open(frame)
        top.it = frame.members()[Symbol.iterator]()
      } else {
        handlers.atom(top.v)
        stack.pop()
        continue
      }
    }
    const { value, done } = top.it.next()
    if (done) {
      handlers.close(top.v)
      stack.pop()
    } else {
      stack.push({ v: value, it: null })
    }
  }
}
