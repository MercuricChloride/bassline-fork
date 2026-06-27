import { describe, it, expect } from 'vitest'
import { fresh } from '@bassline/core/data'
import { sendRepo } from '../src/sends.js'

const { symbol, record, list, int } = fresh

describe('sendRepo', () => {
  it('recovers stored sends from a message that denotes them', () => {
    const repo = sendRepo()
    const log = []
    const reply = v => log.push(['reply', v])
    const reject = v => log.push(['reject', v])

    const replyH = repo.store(reply, 'REPLY')
    const rejectH = repo.store(reject, 'REJECT')

    // `(call [1 2] REPLY REJECT)
    const message = record(
      [symbol('call'), list([int(1n), int(2n)]), replyH, rejectH],
      true
    )

    const found = Array.from(repo.lookup(message))
    expect(found.length).toBe(2)
    expect(found.map(f => f.send)).toEqual(
      expect.arrayContaining([reply, reject])
    )

    // the {handle, send} correlation lets a caller route by position
    const arg = symbol('ok')
    for (const { handle, send } of found) if (handle.eq(replyH)) send(arg)
    expect(log).toEqual([['reply', arg]])
  })

  it('finds a handle nested deep in the message', () => {
    const repo = sendRepo()
    const h = repo.store(() => {})
    const message = record(
      [symbol('outer'), list([record([symbol('inner'), h])])],
      true
    )
    const found = Array.from(repo.lookup(message))
    expect(found.length).toBe(1)
    expect(found[0].handle.eq(h)).toBe(true)
  })

  it('recovers nothing for foreign or absent handles', () => {
    const repo = sendRepo()
    const foreign = sendRepo().store(() => {})
    const message = record([symbol('call'), foreign], true)
    expect(Array.from(repo.lookup(message))).toEqual([])
  })
})
