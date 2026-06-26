//@ts-check
/** @import {Value} from "@bassline/core/data" */
import { fresh, walk } from '@bassline/core/data'

/** @typedef {(v: Value) => void} Send */

export class SendRepo {
  /** @type {Map<string, Send>} */
  byKey = new Map()

  /**
   * Keep `send` locally; return a fresh Value that denotes it.
   * @param {Send} send
   * @param {string} name
   */
  store(send, name = crypto.randomUUID()) {
    if (typeof send !== 'function') {
      throw new TypeError('store expects a send (a function)')
    }
    const handle = fresh.symbol(name, true)
    this.byKey.set(handle.ceKey(), send)
    return handle
  }

  /**
   * @param {Value} handle
   */
  revoke(handle) {
    this.byKey.delete(handle.ceKey())
    return this
  }

  /**
   * Walks a message for each denoting Value this repo issued,
   * recovering its send.
   * @param {Value} message
   * @yields {{handle: Value, send: Send}}
   */
  *lookup(message) {
    for (const node of walk(message)) {
      if (!node.actionable) continue

      const send = this.byKey.get(node.ceKey())

      if (send) yield { handle: node, send }
    }
  }
}

export const sendRepo = () => new SendRepo()
