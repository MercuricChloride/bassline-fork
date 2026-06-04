// [[file:../../../../book.org::*Framing][Framing:1]]
import { is, msg } from '../bassline.js'

export class JSONLFrame {
  buffer = ''
  constructor(aTarget) {
    this.target = aTarget
  }
  readChunk(aString) {
    if (!is.string(aString)) return
    this.buffer += aString
    let nl
    while ((nl = this.buffer.indexOf('\n')) !== -1) {
      const line = this.buffer.slice(0, nl)
      this.buffer = this.buffer.slice(nl + 1)
      if (!line) continue
      try {
        const raw = JSON.parse(line)
        this.target.verb(msg(raw))
      } catch (e) {
        this.onError(e)
      }
    }
  }
  onError(e) {
    console.error('Frame parse error: ', e)
    throw e
  }
  static format(aMsg) {
    //TODO: Make this work properly
    return JSON.stringify(aMsg) + '\n'
  }
}
export function frame(aTarget) {
  return new JSONLFrame(aTarget)
}
export function format(aMsg) {
  return JSONLFrame.format(aMsg)
}
export default { frame, format }
// Framing:1 ends here
