// Built-in affordances and kinds. `format` is offered directly; `export` and
// `endpoint` are document-instantiated kinds that a manifest names. All land in
// the same provider, so every consumer treats them uniformly.
import * as vscode from 'vscode'
import { read } from '@bassline/core/text'
import { encode } from '@bassline/core/data'
import { connect } from '@bassline/comm'
import type { Affordances, RunContext } from './affordances'
import { formatEdits } from './format'
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

  // --- export kind: encode the document's values to canonical bytes --------
  // `<export {name: "ce" path: "out.bin"}>`
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
  // `<endpoint {name: "deploy" host: "127.0.0.1" port: 9000}>`
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
