import { msg } from '@bassline/core'
import { call } from '@bassline/std'
import pane from './pane.js'

export default function lambdaButton(aMsg, mountTo, target = msg()) {
  const root = document.createElement('div')
  root.classList.add('lambda-button')
  mountTo.append(root)
  target.onClose(() => root.remove())

  const description = aMsg.get('description') || '<lambda>'

  const label = document.createElement('span')
  label.classList.add('msg-description')
  label.textContent = description

  const input = document.createElement('input')
  input.classList.add('cap-input')
  input.type = 'text'
  input.placeholder = '{}'

  const btn = document.createElement('button')
  btn.classList.add('cap-invoke', 'lambda')
  btn.textContent = 'call'

  const errSpan = document.createElement('span')
  errSpan.classList.add('cap-error')

  root.append(label, input, btn, errSpan)

  const invoke = async () => {
    errSpan.textContent = ''
    let arg
    try {
      const text = input.value.trim()
      arg = text ? msg(JSON.parse(text)) : msg()
    } catch (e) {
      errSpan.textContent = 'JSON error: ' + e.message
      return
    }
    btn.disabled = true
    try {
      const result = await call(aMsg, arg)
      pane(result, document.querySelector('#panes'))
    } catch (e) {
      errSpan.textContent = 'call error: ' + e.message
    } finally {
      btn.disabled = false
    }
  }

  btn.addEventListener('click', invoke, { signal: target.signal })
  input.addEventListener(
    'keydown',
    e => {
      if (e.key === 'Enter' && !btn.disabled) invoke()
    },
    { signal: target.signal }
  )

  return target
}
