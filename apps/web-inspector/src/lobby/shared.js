import { msg } from '@bassline/core'
import { lambda } from '@bassline/std'
import pane from '../components/pane.js'

const inspect = lambda(
  aMsg => pane(aMsg, document.querySelector('#panes')),
  msg({ description: 'Open a new pane focused on the given message.' })
)

export default msg({ inspect })
