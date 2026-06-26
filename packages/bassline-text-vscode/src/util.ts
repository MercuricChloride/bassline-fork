import * as vscode from 'vscode'

/** The range covering an entire document. */
export const fullRange = (doc: vscode.TextDocument): vscode.Range =>
  new vscode.Range(doc.positionAt(0), doc.positionAt(doc.getText().length))
