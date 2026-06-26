// The provider: a lookup of local affordances, modeled on the SendRepo lookup
// in packages/comm/src/sends.js. Built-ins register concrete affordances with
// `offer`; documents register affordance *kinds* with `kind`, and `load` walks
// a document and constructs one affordance per recognized directive head.
// Consumers (Run QuickPick, CodeLens) read the uniform `byName` set.
import type { Value } from '@bassline/core/data'
import { walk } from '@bassline/core/data'
import { isDirective, headSpelling } from './directives'

/** What an affordance needs from the live editor when it runs. */
export interface RunContext {
  /** The active document, when there is one. */
  document?: import('vscode').TextDocument
}

/** A named, runnable local capability. */
export interface Affordance {
  /** Stable command name (the QuickPick / dispatch key). */
  name: string
  /** Human label shown in the QuickPick / CodeLens. */
  title: string
  run(ctx: RunContext): void | Promise<void>
}

/** Constructs a concrete affordance from a directive form (or declines). */
export type Kind = (directive: Value) => Affordance | undefined

/** A handle that removes whatever a `load` added. */
export interface Disposable {
  dispose(): void
}

export class Affordances {
  private byName = new Map<string, Affordance>()
  private byHead = new Map<string, Kind>()

  /** Register a concrete affordance directly (built-ins). */
  offer(a: Affordance): this {
    this.byName.set(a.name, a)
    return this
  }

  /** Register a constructible affordance kind, keyed by directive head. */
  kind(head: string, make: Kind): this {
    this.byHead.set(head, make)
    return this
  }

  /**
   * Construct (without registering) the affordance a directive denotes. Lets
   * directives in the active document — not just the loaded manifest — drive
   * per-form actions like CodeLens.
   */
  resolve(directive: Value): Affordance | undefined {
    const head = headSpelling(directive)
    const make = head ? this.byHead.get(head) : undefined
    return make?.(directive)
  }

  /**
   * Fold a document's directives into the provider: walk it and register an
   * affordance for each recognized directive head. Returns a handle that
   * removes exactly what this call added, so a reload replaces the previous set.
   */
  load(values: Value[]): Disposable {
    const added: string[] = []
    for (const root of values) {
      for (const v of walk(root)) {
        if (!isDirective(v)) continue
        const aff = this.resolve(v)
        if (!aff) continue
        this.byName.set(aff.name, aff)
        added.push(aff.name)
      }
    }
    return {
      dispose: () => {
        for (const name of added) this.byName.delete(name)
      },
    }
  }

  /** Every affordance currently exposed (for the QuickPick). */
  list(): Affordance[] {
    return [...this.byName.values()]
  }

  get(name: string): Affordance | undefined {
    return this.byName.get(name)
  }
}
