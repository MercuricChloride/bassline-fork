import { msg } from '@bassline/core'
import messageView from './messageView.js'

let paneCount = 0

export default function pane(aMsg, mountTo, target = msg()) {
  const id = ++paneCount

  const root = document.createElement('section')
  root.classList.add('pane')

  const header = document.createElement('div')
  header.classList.add('pane-header')

  const title = document.createElement('span')
  title.classList.add('pane-title')
  title.textContent = `pane ${id}`

  const closeBtn = document.createElement('button')
  closeBtn.classList.add('pane-close')
  closeBtn.textContent = '×'
  closeBtn.title = 'close'

  header.append(title, closeBtn)

  const body = document.createElement('div')
  body.classList.add('pane-body')

  root.append(header, body)
  mountTo.append(root)

  target.onClose(() => root.remove())

  closeBtn.addEventListener('click', () => target.close(), {
    signal: target.signal,
  })

  messageView(aMsg, body).closedBy(target)

  return target.grantCaps({
    close: () => target.close(),
  })
}
