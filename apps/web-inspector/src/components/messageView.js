import { is, msg } from '@bassline/core'
import capForm from './capForm.js'
import lambdaButton from './lambdaButton.js'

export default function messageView(aMsg, mountTo, target = msg()) {
  const root = document.createElement('div')
  root.classList.add('msg')
  mountTo.append(root)
  target.onClose(() => root.remove())

  if (isLambdaShaped(aMsg)) {
    lambdaButton(aMsg, root).closedBy(target)
    return target
  }

  if (aMsg.has('description')) {
    const desc = document.createElement('div')
    desc.classList.add('msg-description')
    desc.textContent = aMsg.get('description')
    root.append(desc)
  }

  for (const [k, v] of Object.entries(aMsg.data)) {
    if (k === 'description') continue
    renderEntry(k, v, root, target)
  }

  for (const spelling of aMsg.capKeys) {
    capForm(aMsg, spelling, root).closedBy(target)
  }

  return target
}

function isLambdaShaped(aMsg) {
  return aMsg.capableOf(['call']) && aMsg.capKeys.length === 1
}

function renderEntry(key, value, mountTo, target) {
  const entry = document.createElement('div')
  entry.classList.add('msg-entry')

  const hasMsgChildren =
    is.msg(value) || (is.array(value) && value.some(is.msg))

  if (hasMsgChildren) {
    entry.classList.add('block')
    const keySpan = document.createElement('div')
    keySpan.classList.add('msg-key')
    keySpan.textContent = key + ':'
    entry.append(keySpan)

    const nested = document.createElement('div')
    nested.classList.add('msg-nested')
    entry.append(nested)
    mountTo.append(entry)

    if (is.msg(value)) {
      messageView(value, nested).closedBy(target)
    } else {
      for (const item of value) {
        if (is.msg(item)) {
          messageView(item, nested).closedBy(target)
        } else {
          const litem = document.createElement('div')
          litem.classList.add('msg-value')
          litem.textContent = JSON.stringify(item)
          nested.append(litem)
        }
      }
    }
  } else {
    const keySpan = document.createElement('span')
    keySpan.classList.add('msg-key')
    keySpan.textContent = key + ':'

    const valSpan = document.createElement('span')
    valSpan.classList.add('msg-value')
    valSpan.textContent = JSON.stringify(value)

    entry.append(keySpan, valSpan)
    mountTo.append(entry)
  }
}
