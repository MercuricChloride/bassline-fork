// The rendering context: immobile local machinery threaded down the tree.
// It is NOT document data and never ships — it carries the live theme, an
// optional evaluation environment, and the affordance sink `dispatch`.
import type { MantineThemeOverride } from '@mantine/core'
import type { Value } from '@bassline/core/data'

export interface Ctx {
  /** Current Mantine theme override (set by a `document`/`theme` directive). */
  theme?: MantineThemeOverride
  /** Depth in the document tree (for keys / debug / nesting limits). */
  depth: number
  /**
   * Affordance + evaluation sink. A node calls this with a value (a message or
   * an actionable program) when an interaction fires. The host decides what to
   * do (evaluate, send, update the document). Default is a no-op.
   */
  dispatch: (value: Value) => void
}

export const defaultCtx: Ctx = {
  depth: 0,
  dispatch: () => {},
}

/** Derive a child context (increments depth, shallow-merges overrides). */
export const childCtx = (ctx: Ctx, over: Partial<Ctx> = {}): Ctx => ({
  ...ctx,
  ...over,
  depth: ctx.depth + 1,
})
