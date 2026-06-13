import { AssertionFailure, failure, is, msg } from '@bassline/core'

export function diff(toAdd = [], toRemove = [], aMsg = msg()) {
  if (!is.array(toAdd)) {
    throw failure(`diff: add must be an array: ${toAdd}`)
  }
  if (!is.array(toRemove)) {
    throw failure(`diff: remove must be an array: ${toRemove}`)
  }
  return aMsg.merge({ add: toAdd, remove: toRemove })
}

export function isDiff(aMsg) {
  try {
    assertDiff(aMsg)
    return true
  } catch (e) {
    if (e instanceof AssertionFailure) return false
    throw e
  }
}

export function assertDiff(aMsg) {
  if (!is.msg(aMsg)) throw failure('diff: expected a Msg')
  if (!is.array(aMsg.get('add'))) {
    throw failure('diff: add must be an array')
  }
  if (!is.array(aMsg.get('remove'))) {
    throw failure('diff: remove must be an array')
  }
  return aMsg
}

export function emptyDiff(aMsg = msg()) {
  return diff([], [], aMsg)
}

export function invertDiff(aDiff, aMsg = msg()) {
  assertDiff(aDiff)
  return diff(aDiff.get('remove'), aDiff.get('add'), aMsg)
}

export function mapDiff(aDiff, fn, aMsg = msg()) {
  assertDiff(aDiff)
  if (!is.fn(fn)) throw failure('mapDiff: fn must be a function')
  return diff(aDiff.get('add').map(fn), aDiff.get('remove').map(fn), aMsg)
}

export function filterDiff(aDiff, pred, aMsg = msg()) {
  assertDiff(aDiff)
  if (!is.fn(pred)) throw failure('filterDiff: pred must be a function')
  return diff(
    aDiff.get('add').filter(pred),
    aDiff.get('remove').filter(pred),
    aMsg
  )
}
