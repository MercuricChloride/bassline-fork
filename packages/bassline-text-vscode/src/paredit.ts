// Structural (paredit-style) editing for bassline, driven entirely by readSpans.
//
// Everything here is pure: `(text, offset) -> { text, offset } | null`. The
// VS Code layer (extension.ts) just reads the cursor, calls one of these, and
// applies the result. That keeps the fiddly offset arithmetic headless-testable.
//
// Contract, as in classic paredit: these preserve DELIMITER balance, not
// semantic validity. Dicts are treated as a flat sequence of forms — key, `:`,
// value are three independent forms — so a slurp/barf may leave a dict that is
// balanced but not a valid set of pairs. That is accepted.
import type { Spanned } from '@bassline/core/text'
import { readSpans } from '@bassline/core/text'

/** A navigable sub-form: just a source range. */
interface Form {
  start: number
  end: number
}

export interface Edit {
  text: string
  offset: number
}

const FRAME = new Set(['list', 'set', 'record', 'dict'])

const isFrame = (n: Spanned): boolean => FRAME.has(n.value.kind)

/** End offset of a frame's opening delimiter — past `[`/`{`/`<`, or `#{`. */
function openerEnd(frame: Spanned, src: string): number {
  let i = frame.start
  while (src[i] === '`') i++ // the actionable mark belongs to the opener
  return src[i] === '#' ? i + 2 : i + 1
}

/** Offset of a frame's (single-character) closing delimiter. */
const closerStart = (frame: Spanned): number => frame.end - 1

/**
 * The navigable child forms of a frame in document order. For dicts this
 * synthesizes a form for each `:` (which readSpans omits) so key, colon, and
 * value are independent forms.
 */
function childForms(frame: Spanned, src: string): Form[] {
  if (frame.value.kind !== 'dict') {
    return frame.children.map(c => ({ start: c.start, end: c.end }))
  }
  const forms: Form[] = []
  const ch = frame.children
  for (let i = 0; i + 1 < ch.length; i += 2) {
    const key = ch[i]
    const val = ch[i + 1]
    const colon = src.indexOf(':', key.end)
    forms.push({ start: key.start, end: key.end })
    forms.push({ start: colon, end: colon + 1 })
    forms.push({ start: val.start, end: val.end })
  }
  return forms
}

const topForms = (roots: Spanned[]): Form[] =>
  roots.map(r => ({ start: r.start, end: r.end }))

/** Root → innermost path of spanned nodes containing `offset`. */
function pathAt(roots: Spanned[], offset: number): Spanned[] {
  const path: Spanned[] = []
  let level = roots
  for (;;) {
    const node = level.find(n => offset >= n.start && offset <= n.end)
    if (!node) return path
    path.push(node)
    if (node.children.length === 0) return path
    level = node.children
  }
}

interface Site {
  /** The frame the cursor is operating in. */
  frame: Spanned
  /** Sibling forms of `frame` within its parent (or the document). */
  siblings: Form[]
  /** Index of `frame` among `siblings`. */
  index: number
}

/** Locate the innermost frame at `offset` and its position among siblings. */
function siteAt(roots: Spanned[], offset: number, src: string): Site | null {
  const path = pathAt(roots, offset)
  let frameIdx = -1
  for (let i = path.length - 1; i >= 0; i--) {
    if (isFrame(path[i])) {
      frameIdx = i
      break
    }
  }
  if (frameIdx === -1) return null
  const frame = path[frameIdx]

  let parent: Spanned | null = null
  for (let i = frameIdx - 1; i >= 0; i--) {
    if (isFrame(path[i])) {
      parent = path[i]
      break
    }
  }
  const siblings = parent ? childForms(parent, src) : topForms(roots)
  const index = siblings.findIndex(s => s.start === frame.start)
  return { frame, siblings, index }
}

/** Clamp a cursor offset into a freshly produced text. */
const clamp = (offset: number, text: string): number =>
  Math.max(0, Math.min(offset, text.length))

/** Parse, locate the site, and run `op`; null on any failure or no-op. */
function structural(
  text: string,
  offset: number,
  op: (site: Site, frame: Spanned, src: string) => string | null
): Edit | null {
  let roots: Spanned[]
  try {
    roots = readSpans(text)
  } catch {
    return null
  }
  const site = siteAt(roots, offset, text)
  if (!site) return null
  const next = op(site, site.frame, text)
  return next === null ? null : { text: next, offset: clamp(offset, next) }
}

/** Pull the next sibling of the frame inside its closing delimiter. */
export function slurpForward(text: string, offset: number): Edit | null {
  return structural(text, offset, (site, frame, src) => {
    const next = site.siblings[site.index + 1]
    if (!next) return null
    const kids = childForms(frame, src)
    const innerEnd = kids.length
      ? kids[kids.length - 1].end
      : openerEnd(frame, src)
    const sep = kids.length ? ' ' : ''
    return (
      src.slice(0, innerEnd) +
      sep +
      src.slice(next.start, next.end) +
      src[closerStart(frame)] +
      src.slice(next.end)
    )
  })
}

/** Expel the frame's last child past its closing delimiter. */
export function barfForward(text: string, offset: number): Edit | null {
  return structural(text, offset, (site, frame, src) => {
    const kids = childForms(frame, src)
    if (kids.length === 0) return null
    const last = kids[kids.length - 1]
    const keepEnd =
      kids.length > 1 ? kids[kids.length - 2].end : openerEnd(frame, src)
    return (
      src.slice(0, keepEnd) +
      src[closerStart(frame)] +
      ' ' +
      src.slice(last.start, last.end) +
      src.slice(frame.end)
    )
  })
}

/** Pull the previous sibling of the frame inside its opening delimiter. */
export function slurpBackward(text: string, offset: number): Edit | null {
  return structural(text, offset, (site, frame, src) => {
    const prev = site.siblings[site.index - 1]
    if (!prev) return null
    const opener = src.slice(frame.start, openerEnd(frame, src))
    const kids = childForms(frame, src)
    const innerStart = kids.length ? kids[0].start : closerStart(frame)
    const sep = kids.length ? ' ' : ''
    return (
      src.slice(0, prev.start) +
      opener +
      src.slice(prev.start, prev.end) +
      sep +
      src.slice(innerStart, frame.end) +
      src.slice(frame.end)
    )
  })
}

/** Expel the frame's first child past its opening delimiter. */
export function barfBackward(text: string, offset: number): Edit | null {
  return structural(text, offset, (site, frame, src) => {
    const kids = childForms(frame, src)
    if (kids.length === 0) return null
    const first = kids[0]
    const opener = src.slice(frame.start, openerEnd(frame, src))
    const keepStart = kids.length > 1 ? kids[1].start : closerStart(frame)
    return (
      src.slice(0, frame.start) +
      src.slice(first.start, first.end) +
      ' ' +
      opener +
      src.slice(keepStart, frame.end) +
      src.slice(frame.end)
    )
  })
}
