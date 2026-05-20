import { is } from '@bassline/core'

export function countWords(aMsg) {
  const counts = {
    data: {},
    caps: {},
  }

  return count(aMsg)

  function inc(aKey, isCap = false) {
    const dict = isCap ? counts.caps : counts.data
    const n = dict[aKey] ?? 0
    dict[aKey] = n + 1
  }

  function count(aValue) {
    if (is.msg(aValue)) {
      Object.keys(aValue.caps).forEach(k => inc(k, true))
      count(aValue.data)
    } else if (is.array(aValue)) {
      aValue.forEach(count)
    } else if (is.object(aValue)) {
      for (const [key, value] of Object.entries(aValue)) {
        inc(key)
        count(value)
      }
    }
    return counts
  }
}
