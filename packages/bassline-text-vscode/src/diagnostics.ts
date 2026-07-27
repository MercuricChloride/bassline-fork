// Diagnostics from the canonical reader: `read` throws a ReaderError with
// pos/line/col, which becomes one squiggle. Catches structural errors the
// TextMate grammar can't (unterminated literals, bad hex, empty records, …).
import * as vscode from 'vscode'
import { read, ReaderError } from '@bassline/core/text'

function diagnose(doc: vscode.TextDocument): vscode.Diagnostic[] {
  try {
    read(doc.getText())
    return []
  } catch (e) {
    if (!(e instanceof ReaderError)) throw e
    const pos = new vscode.Position(
      Math.max(0, e.line - 1),
      Math.max(0, e.col - 1)
    )
    const range = doc.getWordRangeAtPosition(pos) ?? new vscode.Range(pos, pos)
    return [
      new vscode.Diagnostic(range, e.message, vscode.DiagnosticSeverity.Error),
    ]
  }
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
