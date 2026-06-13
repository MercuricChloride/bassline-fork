import { msg } from '@bassline/core'
import { call } from '@bassline/std'

export default async function seed(lobby) {
  console.log('[daemon] seeding demo data')

  const write = lobby.get('bindings').get('write')
  await call(
    write,
    msg({ key: 'greeting', val: msg({ text: 'hello from bassline' }) })
  )
  await call(
    write,
    msg({ key: 'startedAt', val: msg({ time: new Date().toISOString() }) })
  )

  const post = lobby.get('graph').get('post')
  const alice = await call(post, msg({ name: 'alice', role: 'designer' }))
  const bob = await call(post, msg({ name: 'bob', role: 'engineer' }))
  await call(post, msg({ name: 'charlie', role: 'pm' }))

  await call(
    alice.get('link'),
    msg({
      related: msg({ name: 'bob', role: 'engineer' }),
      by: 'collaborates_with',
    })
  )
  await call(
    alice.get('link'),
    msg({
      related: msg({ name: 'charlie', role: 'pm' }),
      by: 'collaborates_with',
    })
  )
  await call(
    bob.get('link'),
    msg({
      related: msg({ title: 'design system v2', stage: 'draft' }),
      by: 'owns',
    })
  )

  console.log('[daemon] seed complete')
}
