// Activation: syntax highlighting comes from the TextMate grammar; the only
// live piece is reader-backed diagnostics.
import * as vscode from 'vscode'
import { registerDiagnostics } from './diagnostics'

export function activate(context: vscode.ExtensionContext): void {
  registerDiagnostics(context)
}

export function deactivate(): void {}
