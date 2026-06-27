// Built-in affordances and kinds. `format` is offered directly; `export` and
// `endpoint` are document-instantiated kinds that a manifest names. All land in
// the same provider, so every consumer treats them uniformly.
import * as vscode from 'vscode'
import { read, print, readSpans } from '@bassline/core/text'
import type { Spanned } from '@bassline/core/text'
import { encode, fresh } from '@bassline/core/data'
import type { Value } from '@bassline/core/data'
import {
  connect,
  BorthEvaluator,
  isBorthDocument,
  isBorthExpression,
  isStackDirective,
} from '@bassline/comm'
import type { Affordances, RunContext } from './affordances'
import { formatEdits, configuredWidth } from './format'
import { paramsOf, at, asString, asNumber, isComment } from './directives'

function activeDoc(ctx: RunContext): vscode.TextDocument | undefined {
  const doc = ctx.document
  if (!doc) {
    vscode.window.showWarningMessage('Bassline: no active document.')
    return undefined
  }
  return doc
}

function resolveInWorkspace(rel: string): vscode.Uri | undefined {
  const folders = vscode.workspace.workspaceFolders
  if (!folders) return undefined
  return vscode.Uri.joinPath(folders[0].uri, rel)
}

/**
 * Persist the result stack as the document's state. Only the `(stack …)` form is
 * touched: it is replaced in place with the final stack (or appended if the
 * document has none). Every other form — including the `(borth …)` blocks — is
 * left exactly as written, so the program stays in the document.
 */
async function persistStack(
  doc: vscode.TextDocument,
  stack: Value[]
): Promise<void> {
  const text = doc.getText()
  const stackSpan = readSpans(text).find(s => isStackDirective(s.value))
  const stackForm = print(
    fresh.record([fresh.symbol('stack'), ...stack], true),
    configuredWidth()
  )
  const edit = new vscode.WorkspaceEdit()
  if (stackSpan) {
    edit.replace(
      doc.uri,
      new vscode.Range(
        doc.positionAt(stackSpan.start),
        doc.positionAt(stackSpan.end)
      ),
      stackForm
    )
  } else {
    const sep = text.endsWith('\n') ? '\n' : '\n\n'
    edit.insert(doc.uri, doc.positionAt(text.length), `${sep}${stackForm}\n`)
  }
  await vscode.workspace.applyEdit(edit)
}

/**
 * Read the document, confirm it is a borth document, run `evaluate` against a
 * fresh evaluator, then persist the resulting stack. `evaluate` receives the
 * spans so callers can target a single block by source offset.
 */
async function withBorthDoc(
  doc: vscode.TextDocument,
  evaluate: (ev: BorthEvaluator, spans: Spanned[]) => void
): Promise<void> {
  let spans: Spanned[]
  try {
    spans = readSpans(doc.getText())
  } catch (e) {
    vscode.window.showErrorMessage(`Bassline evaluate: ${String(e)}`)
    return
  }
  if (!isBorthDocument(spans.map(s => s.value))) {
    vscode.window.showInformationMessage(
      'Bassline: not a borth document (needs a `(lang borth) directive).'
    )
    return
  }
  try {
    const ev = new BorthEvaluator().init()
    evaluate(ev, spans)
    await persistStack(doc, ev.stack)
  } catch (e) {
    vscode.window.showErrorMessage(`Bassline evaluate: ${String(e)}`)
  }
}

/**
 * Evaluate only the `(borth …)` block that starts at `start` (used by the
 * per-block CodeLens), advancing the document's `(stack …)`.
 */
export async function evaluateBlockAt(
  doc: vscode.TextDocument,
  start: number
): Promise<void> {
  await withBorthDoc(doc, (ev, spans) => {
    const span = spans.find(s => s.start === start)
    if (span && isBorthExpression(span.value)) {
      ev.evaluateBlock(
        spans.map(s => s.value),
        span.value
      )
    }
  })
}

export function registerBuiltins(provider: Affordances): void {
  // --- format: apply the canonical printer as a workspace edit -------------
  provider.offer({
    name: 'format',
    title: 'Format Document',
    run: async ctx => {
      const doc = activeDoc(ctx)
      if (!doc) return
      const edits = formatEdits(doc)
      if (edits.length === 0) return
      const edit = new vscode.WorkspaceEdit()
      edit.set(doc.uri, edits)
      await vscode.workspace.applyEdit(edit)
    },
  })

  // --- evaluate: run the document's `(lang …)` evaluator, persist its state ---
  // borth: a document opens with `(lang borth). `(def {…})` blocks bind first,
  // `(stack …)` seeds the stack, then `(borth …)` blocks evaluate in order. Only
  // the `(stack …)` form is rewritten with the result (see persistStack); the
  // `(borth …)` blocks stay, so each evaluation runs them again from the new
  // stack — re-evaluating advances the state.
  provider.offer({
    name: 'evaluate',
    title: 'Evaluate Document',
    run: async ctx => {
      const doc = activeDoc(ctx)
      if (!doc) return
      await withBorthDoc(doc, (ev, spans) =>
        ev.evaluateDocument(spans.map(s => s.value))
      )
    },
  })

  // --- export kind: encode the document's values to canonical bytes --------
  // `(export {name: "ce" path: "out.bin"})`
  provider.kind('export', directive => {
    const params = paramsOf(directive)
    const name = asString(at(params, 'name')) ?? 'export'
    const path = asString(at(params, 'path'))
    return {
      name,
      title: `Export → ${path ?? name}`,
      run: async ctx => {
        const doc = activeDoc(ctx)
        if (!doc) return
        if (!path) {
          vscode.window.showErrorMessage(
            `Bassline export "${name}": missing "path".`
          )
          return
        }
        const dest = resolveInWorkspace(path)
        if (!dest) {
          vscode.window.showErrorMessage(
            'Bassline export: no workspace folder.'
          )
          return
        }
        // A comment is "drop me": exclude it from the serialized output.
        const values = read(doc.getText()).filter(v => !isComment(v))
        const bytes = Buffer.concat(values.map(v => Buffer.from(encode(v))))
        await vscode.workspace.fs.writeFile(dest, bytes)
        vscode.window.showInformationMessage(
          `Bassline: exported ${values.length} value(s) → ${path}`
        )
      },
    }
  })

  // --- endpoint kind: stream the document's values to a running socket -----
  // `(endpoint {name: "deploy" host: "127.0.0.1" port: 9000})`
  provider.kind('endpoint', directive => {
    const params = paramsOf(directive)
    const name = asString(at(params, 'name')) ?? 'endpoint'
    const host = asString(at(params, 'host')) ?? '127.0.0.1'
    const port = asNumber(at(params, 'port'))
    return {
      name,
      title: `Send via ${name} (${host}:${port ?? '?'})`,
      run: async ctx => {
        const doc = activeDoc(ctx)
        if (!doc) return
        if (port === undefined) {
          vscode.window.showErrorMessage(
            `Bassline endpoint "${name}": missing "port".`
          )
          return
        }
        const values = read(doc.getText())
        // connect() is async: report success only after a clean connect + send +
        // close, and report failure (ENOTFOUND, ECONNREFUSED, …) instead.
        try {
          await new Promise<void>((resolve, reject) => {
            const conn = connect({ host, port })
            conn.socket.once('error', reject)
            conn.socket.once('connect', () => {
              for (const v of values) conn.send(v)
              conn.socket.end() // flush, then half-close on a value boundary
            })
            conn.socket.once('close', hadError => {
              if (!hadError) resolve()
            })
          })
          vscode.window.showInformationMessage(
            `Bassline: sent ${values.length} value(s) → ${name}`
          )
        } catch (e) {
          vscode.window.showErrorMessage(
            `Bassline endpoint "${name}": ${String(e)}`
          )
        }
      },
    }
  })
}
