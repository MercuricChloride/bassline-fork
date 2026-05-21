import { fromWebSocket } from '@bassline/core/transports'
import { dialogue } from '@bassline/std'
import sharedLobby from './lobby/shared.js'
import './lobby/index.js'

const statusEl = document.querySelector('#status')

const wsUrl = `ws://${location.hostname}:7077`
const ws = new WebSocket(wsUrl)

ws.addEventListener('open', () => {
  statusEl.textContent = 'connected'
  statusEl.classList.add('connected')

  const [conn] = dialogue(fromWebSocket(ws))
  conn.send(sharedLobby)
})

ws.addEventListener('close', () => {
  statusEl.textContent = 'disconnected'
  statusEl.classList.remove('connected')
  statusEl.classList.add('disconnected')
})

ws.addEventListener('error', e => {
  console.error('ws error', e)
})
