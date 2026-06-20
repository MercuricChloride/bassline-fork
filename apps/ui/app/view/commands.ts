// Commands: the messages a view (a participant) accepts. A command is recognized
// by shape and run for effect — like the render vocab, it's a [predicate, handler]
// table, extended by adding a row. Argument values are resolved HERE, at dispatch
// time, so a deferred handler ref (e.g. `on-click: `<set out `src>`) sees the
// current binding rather than one captured at render.
import type { Value } from '@bassline/core/data'
import { kind } from '@bassline/core/match'
import { resolve, type Store } from './bindings'
import { headed, type Predicate } from './match'

export interface CommandApi {
  store: Store
  setBinding: (name: Value, value: Value) => void
}

export type Command = (msg: Value, api: CommandApi) => void

/** `<set name value>` — bind `name` to `value`, resolved now. */
const setCmd: Command = (msg, api) => {
  if (!kind.record(msg)) return
  const [name, expr] = msg.fields
  if (name && kind.symbol(name) && expr)
    api.setBinding(name, resolve(expr, api.store))
}

export const COMMANDS: Array<[Predicate, Command]> = [[headed('set'), setCmd]]

/** Run the first command whose predicate matches the message; ignore the rest. */
export function runCommand(msg: Value, api: CommandApi): void {
  for (const [pred, cmd] of COMMANDS) {
    if (pred(msg)) {
      cmd(msg, api)
      return
    }
  }
}
