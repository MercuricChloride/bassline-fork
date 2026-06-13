#!/usr/bin/env node
import { WebSocketServer } from 'ws'
import { serveTcp, serveWs } from '@bassline/core/serve'
import { context, conversation, call } from '@bassline/std'
import { localBindings } from './lobby/locals.js'
import lobby from './lobby/server-lobby.js'
import seed from './seed.js'

const [, , socketPath = '/tmp/bassline.sock', wsPort = '7077'] = process.argv

const ctx = context()
const { dispatch, mintId } = ctx

const [tcpServer] = serveTcp(onConnect, { path: socketPath })

const wss = new WebSocketServer({ port: Number(wsPort) })
const [wsServer] = serveWs(wss, onConnect)

function onConnect([peer, recv]) {
  const [conv, onMsg] = conversation(peer, { recv, dispatch, mintId })
  conv.closeGroup(peer).send(lobby)
  onMsg(async peerLobby => {
    const inspect = peerLobby.get?.('inspect')
    if (!inspect) return
    try {
      await call(inspect, lobby.copy())
    } catch (e) {
      const reason = e?.get?.('error') ?? e?.message ?? e
      console.error('[daemon] inspect on peer failed:', reason)
    }
  })
}

seed(lobby).catch(e => {
  const reason = e?.get?.('error') ?? e?.message ?? e
  console.error('[daemon] seed failed:', reason)
})

process.on('SIGINT', onClose)
process.on('SIGTERM', onClose)

const interval = setInterval(() => {
  console.log(
    `[daemon] ctx entries: ${ctx.entries().length}, bindings: ${Object.keys(localBindings).length}`
  )
}, 1000)

function onClose() {
  tcpServer.close()
  wsServer.close()
  clearInterval(interval)
}

console.log(`daemon listening on ${socketPath} and ws://localhost:${wsPort}`)
