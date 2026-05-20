#!/usr/bin/env node
import { msg } from '@bassline/core'
import { connect } from '@bassline/core/transports/node'
import { dialogue, call } from '@bassline/std'
import myLobby from './lobby/index.js'

const [, , socketPath = '/tmp/bassline.sock'] = process.argv

const inspector = myLobby.get('inspector')

const [conn, onMsg] = dialogue(connect({ path: socketPath }))

onMsg(async lobby => {
  inspector.send(lobby)

  const [r, w] = lobby.get('bindings').get(['read', 'write'])
  await call(w, msg({ key: 'foo', val: msg({ hello: Date.now().toString() }) }))

  const g = lobby.get('graph')

  const aliceEntry = await call(g.get('post'), msg({ name: 'alice' }))
  console.log('\n[client] posted alice:')
  inspector.send(aliceEntry)

  const edge = await call(
    aliceEntry.get('link'),
    msg({ related: msg({ name: 'bob' }), by: 'knows' })
  )
  console.log('\n[client] alice <knows:> bob')
  inspector.send(edge)

  console.log('\n[client] alice outgoing:')
  inspector.send(await call(aliceEntry.get('outgoing')))

  edge.invoke('remove')

  console.log('\n[client] alice outgoing:')
  inspector.send(await call(aliceEntry.get('outgoing')))

  const interval = setInterval(async () => {
    inspector.send(await call(r, msg({ key: 'foo' })))
  }, 500)

  conn.onClose(() => clearInterval(interval))
})

process.on('SIGINT', onClose)
process.on('SIGTERM', onClose)

function onClose() {
  conn.close()
}
