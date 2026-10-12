// Diagnostics from the petit-parser reader: a failed read reports the
// furthest position reached and what was expected there, which becomes
// one squiggle. Catches what the TextMate grammar can't (unterminated
// literals, bad hex, empty records, duplicate members, …).
import * as vscode from 'vscode'
import { parseBassline } from './generated/reader.mjs'

function diagnose(doc: vscode.TextDocument): vscode.Diagnostic[] {
  const r = parseBassline(doc.getText())
  if (r.error === undefined) return []
  const pos = doc.positionAt(r.offset)
  const range = doc.getWordRangeAtPosition(pos) ?? new vscode.Range(pos, pos)
  return [
    new vscode.Diagnostic(range, r.error, vscode.DiagnosticSeverity.Error),
  ]
}

/** Wire up always-on, edit-driven diagnostics for bassline documents. */
export function registerDiagnostics(context: vscode.ExtensionContext): void {
  const collection = vscode.languages.createDiagnosticCollection('bassline')
  const lint = (doc: vscode.TextDocument) => {
    if (doc.languageId !== 'bassline') return
    collection.set(doc.uri, diagnose(doc))
  }

  context.subscriptions.push(
    collection,
    vscode.workspace.onDidOpenTextDocument(lint),
    vscode.workspace.onDidChangeTextDocument(e => lint(e.document)),
    vscode.workspace.onDidCloseTextDocument(doc => collection.delete(doc.uri))
  )
  vscode.workspace.textDocuments.forEach(lint)
}
