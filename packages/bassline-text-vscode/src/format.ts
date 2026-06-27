// Formatting reuses the canonical printer (packages/core/src/text/print.js).
// Parse errors belong to diagnostics, so on a read failure we make no edit.
import * as vscode from 'vscode'
import { read, print } from '@bassline/core/text'
import { fullRange } from './util'

/** The default print width when no configuration is present. */
export const DEFAULT_WIDTH = 72

/** Render a whole document: each top-level value printed, blank line between. */
export function formatText(
  text: string,
  width: number = DEFAULT_WIDTH
): string {
  const values = read(text)
  if (values.length === 0) return ''
  return values.map(v => print(v, width)).join('\n\n') + '\n'
}

export function configuredWidth(): number {
  return vscode.workspace
    .getConfiguration('bassline')
    .get<number>('formatWidth', DEFAULT_WIDTH)
}

/** A full-document replacement edit, or [] when the source does not parse. */
export function formatEdits(doc: vscode.TextDocument): vscode.TextEdit[] {
  let out: string
  try {
    out = formatText(doc.getText(), configuredWidth())
  } catch {
    return []
  }
  return [vscode.TextEdit.replace(fullRange(doc), out)]
}

export function registerFormatter(): vscode.Disposable {
  return vscode.languages.registerDocumentFormattingEditProvider(
    'bassline-text',
    {
      provideDocumentFormattingEdits: doc => formatEdits(doc),
    }
  )
}
