import { is, propagator } from '@bassline/core'

const STR_MAX = 80
const DEPTH_MAX = 6

export const [inspector, onMsg] = propagator()

export default inspector

onMsg(m => console.log(pp(m)))

export function pp(value, depth = 0) {
  if (depth > DEPTH_MAX) return '…'
  if (is.msg(value)) return ppMsg(value, depth)
  if (is.string(value))
    return JSON.stringify(
      value.length > STR_MAX ? value.slice(0, STR_MAX) + '…' : value
    )
  if (is.array(value))
    return '[' + value.map(v => pp(v, depth + 1)).join(', ') + ']'
  if (is.fn(value)) return '<fn>'
  if (is.object(value)) return ppObject(value, depth)
  return String(value)
}

function ppMsg(m, depth) {
  const cap = m.capKeys.length ? '<' + m.capKeys.join(', ') + '>' : ''
  if (m.keys.length === 0) return 'Msg' + cap + (cap ? '' : ' {}')
  return 'Msg' + cap + ' ' + ppObject(m.data, depth)
}

function ppObject(obj, depth) {
  const entries = Object.entries(obj)
  if (entries.length === 0) return '{}'
  return (
    '{ ' +
    entries.map(([k, v]) => `${k}: ${pp(v, depth + 1)}`).join(', ') +
    ' }'
  )
}
