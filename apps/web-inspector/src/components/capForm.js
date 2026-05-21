import { msg } from '@bassline/core'

export default function capForm(aMsg, spelling, mountTo, target = msg()) {
  const root = document.createElement('div')
  root.classList.add('cap-form')
  mountTo.append(root)
  target.onClose(() => root.remove())

  const label = document.createElement('span')
  label.classList.add('cap-spelling')
  label.textContent = spelling

  const input = document.createElement('input')
  input.classList.add('cap-input')
  input.type = 'text'
  input.placeholder = '{}'

  const btn = document.createElement('button')
  btn.classList.add('cap-invoke')
  btn.textContent = 'invoke'

  const errSpan = document.createElement('span')
  errSpan.classList.add('cap-error')

  root.append(label, input, btn, errSpan)

  const invoke = () => {
    errSpan.textContent = ''
    let arg
    try {
      const text = input.value.trim()
      arg = text ? msg(JSON.parse(text)) : msg()
    } catch (e) {
      errSpan.textContent = 'JSON error: ' + e.message
      return
    }
    aMsg.invoke(spelling, arg)
  }

  btn.addEventListener('click', invoke, { signal: target.signal })
  input.addEventListener(
    'keydown',
    e => {
      if (e.key === 'Enter') invoke()
    },
    { signal: target.signal }
  )

  return target
}
