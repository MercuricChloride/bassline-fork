import { failure, is, msg } from '@bassline/core'
import { lambda } from '@bassline/std'

const description = `\
I am a property graph.
Post messages to me to mint entries, then link entries by relation.
Edges are themselves messages with a remove cap.`

export function createGraph(target = msg()) {
  const entries = new Map()
  const edges = new Set()

  const post = lambda(
    aMsg => entryFor(aMsg),
    msg({
      description: 'Post a msg; returns its entry handle (idempotent).',
    })
  )

  const all = lambda(
    () => msg({ entries: [...entries.values()] }),
    msg({ description: 'List every entry currently in the graph.' })
  )

  return target.defaults({ description }).merge({ post, all })

  function entryFor(aMsg) {
    if (!is.msg(aMsg)) throw failure('graph: expected a Msg')
    if (entries.has(aMsg)) return entries.get(aMsg)

    const read = lambda(
      () => aMsg,
      msg({ description: 'Return the originally posted message.' })
    )

    const remove = lambda(
      () => void entry.close(),
      msg({ description: 'Remove this entry and cascade-close its edges.' })
    )

    const link = lambda(
      linkFrom,
      msg({
        description:
          'Requires {related, by}. Auto-posts `related` if new. ' +
          'Returns the edge msg, which carries a `remove` cap.',
      })
    )

    const outgoing = lambda(
      () => msg({ edges: filterEdges(e => e.get('source') === entry) }),
      msg({ description: 'Edges where this entry is the source.' })
    )

    const incoming = lambda(
      () => msg({ edges: filterEdges(e => e.get('target') === entry) }),
      msg({ description: 'Edges where this entry is the target.' })
    )

    const entry = msg({ read, remove, link, outgoing, incoming })

    entries.set(aMsg, entry)
    entry.onClose(() => entries.delete(aMsg))

    return entry

    function linkFrom(req) {
      if (!req.has(['related', 'by'])) {
        throw failure('link: requires {related, by}')
      }
      const [related, by] = req.get(['related', 'by'])
      if (!is.msg(related)) throw failure('link: `related` must be a Msg')
      if (!is.string(by)) throw failure('link: `by` must be a string')

      const targetEntry = entryFor(related)
      const edge = msg({ source: entry, target: targetEntry, relation: by })
      edge.grantCaps({ remove: () => edge.close() })

      edges.add(edge)
      entry.closes(edge)
      targetEntry.closes(edge)
      edge.onClose(() => edges.delete(edge))

      return edge
    }
  }

  function filterEdges(pred) {
    const out = []
    for (const e of edges) if (pred(e)) out.push(e)
    return out
  }
}

export default createGraph()
