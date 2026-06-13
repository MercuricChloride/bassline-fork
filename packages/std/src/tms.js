import { msg, propagator } from '@bassline/core'

export function assumption(description, onClose) {
  const supports = new Set()

  const m = msg({ description })
    .grantCaps({
      send: support,
      supports: support,
    })
    .onClose(cleanup)

  return [m, supports]

  function support(aMsg) {
    supports.add(aMsg)
    aMsg.onClose(() => supports.delete(aMsg))
  }

  function cleanup() {
    if (onClose) {
      onClose(supports)
    } else {
      for (const m of supports) m.close()
    }
    m.close()
    supports.clear()
  }
}

export function derive(fn) {
  return propagator((aMsg, send) => {
    fn(aMsg, m => {
      aMsg.closes(m)
      send(m)
    })
  })
}
