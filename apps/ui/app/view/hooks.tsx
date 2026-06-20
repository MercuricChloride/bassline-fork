// View hooks: the coherent surface for nodes to read/write the document's
// bindings and reach shared machinery, replacing the old manual ctx threading.
// A single React state cell holds the whole binding store; every consumer
// re-renders on change, so `` `name `` stays live.
import {
  createContext,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import type { Value } from '@bassline/core/data'
import {
  type Binding,
  keyOf,
  nameOf,
  resolve,
  seed,
  type Store,
} from './bindings'
import { collect } from './collect'
import { runCommand } from './commands'
import { makeRx, recognize, type Recognizers } from './consume'
import { dialectFor, type Dialect } from './dialects'
import { Render } from './render'

interface ViewApi {
  store: Store
  setBinding: (name: Value, value: Value) => void
  /** Run an actionable message (today: `<set name value>`); ignores the rest. */
  dispatch: (msg: Value) => void
}

const ViewContext = createContext<ViewApi | null>(null)

export function DocumentView({ doc }: { doc: Value }) {
  const [store, setStore] = useState<Store>(() => seed(doc))

  const api = useMemo<ViewApi>(() => {
    const setBinding = (name: Value, value: Value) =>
      setStore(prev => {
        const next = new Map(prev)
        const k = keyOf(name)
        const existing = next.get(k)
        next.set(k, {
          sym: nameOf(name),
          value,
          custom: existing?.custom ?? false,
          def: existing?.def,
        })
        return next
      })

    const dispatch = (msg: Value) => runCommand(msg, { store, setBinding })

    return { store, setBinding, dispatch }
  }, [store])

  return (
    <ViewContext.Provider value={api}>
      <Render value={doc} />
    </ViewContext.Provider>
  )
}

function useView(): ViewApi {
  const api = useContext(ViewContext)
  if (!api) throw new Error('view hooks require a <DocumentView> provider')
  return api
}

/** Resolve a value (dereference a marked symbol) against the live store. */
export function useResolve(): (v: Value) => Value {
  const { store } = useView()
  return v => resolve(v, store)
}

/** The affordance / message sink. */
export function useDispatch(): (msg: Value) => void {
  return useView().dispatch
}

/**
 * Fold a recognition table over a node's directives, reactively. The `table`
 * and `init` must be stable (module-level) so the memo holds; it re-folds when
 * the node or the binding store changes (so config that reads `rx.flat/deep`
 * stays live). Directives are NOT pre-resolved — each rule resolves what it
 * treats as config and leaves deferred handlers raw.
 */
export function useDirectives<T>(
  node: Value,
  table: Recognizers<T>,
  init: T
): T {
  const { store } = useView()
  return useMemo(
    () => recognize(collect(node).directives, table, init, makeRx(store)),
    [node, store, table, init]
  )
}

/** The resolver toolkit (flat/deep/raw) against the live store, for ad-hoc use. */
export function useRx() {
  return makeRx(useView().store)
}

/** A document binding as a reactive cell: `[value, setValue]`. */
export function useBinding(
  name: Value
): [Value | undefined, (v: Value) => void] {
  const { store, setBinding } = useView()
  return [store.get(keyOf(name))?.value, v => setBinding(name, v)]
}

/** Every custom binding (declared via def-custom) — enumerable for option panels. */
export function useCustomBindings(): Binding[] {
  return [...useView().store.values()].filter(b => b.custom)
}

export function useDialect(lang: string | undefined): Dialect | undefined {
  return dialectFor(lang)
}

export type { ReactNode }
