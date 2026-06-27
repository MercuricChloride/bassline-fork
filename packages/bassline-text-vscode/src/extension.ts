// Activation: build the provider, register built-ins, auto-load the workspace
// manifest, then register the VS Code surface (commands, Run QuickPick,
// formatter, diagnostics, CodeLens, semantic tokens, paredit) on top.
import * as vscode from 'vscode'
import { read, readSpans } from '@bassline/core/text'
import { Affordances, type RunContext, type Disposable } from './affordances'
import { registerBuiltins, evaluateBlockAt } from './builtins'
import { registerDiagnostics } from './diagnostics'
import { registerFormatter } from './format'
import { registerCodeLens } from './codelens'
import { registerSemanticTokens } from './semanticTokens'
import { symbolsIn } from './completion'
import { fullRange } from './util'
import {
  barfBackward,
  barfForward,
  slurpBackward,
  slurpForward,
  type Edit,
} from './paredit'

function manifestPath(): string {
  return vscode.workspace
    .getConfiguration('bassline')
    .get<string>('manifest', 'bassline.config.blt')
}

async function readDocument(uri: vscode.Uri): Promise<ReturnType<typeof read>> {
  const bytes = await vscode.workspace.fs.readFile(uri)
  return read(Buffer.from(bytes).toString('utf8'))
}

export function activate(context: vscode.ExtensionContext): void {
  const provider = new Affordances()
  registerBuiltins(provider)

  // Symbol completion reuses the last successful parse while the document is
  // mid-edit and unparseable.
  const symbolCache = new WeakMap<vscode.TextDocument, string[]>()
  const completion = vscode.languages.registerCompletionItemProvider(
    'bassline-text',
    {
      provideCompletionItems(doc) {
        const parsed = symbolsIn(doc.getText())
        if (parsed) symbolCache.set(doc, parsed)
        return (symbolCache.get(doc) ?? []).map(
          s => new vscode.CompletionItem(s, vscode.CompletionItemKind.Variable)
        )
      },
    }
  )

  // The active document is the run context for every affordance.
  const ctx = (): RunContext => ({
    document: vscode.window.activeTextEditor?.document,
  })

  // Run a pure structural edit at the cursor and reflect it back into the editor.
  const paredit =
    (op: (text: string, offset: number) => Edit | null) => async () => {
      const editor = vscode.window.activeTextEditor
      if (!editor || editor.document.languageId !== 'bassline-text') return
      const doc = editor.document
      const result = op(doc.getText(), doc.offsetAt(editor.selection.active))
      if (!result) return
      await editor.edit(b => b.replace(fullRange(doc), result.text))
      const pos = doc.positionAt(result.offset)
      editor.selection = new vscode.Selection(pos, pos)
    }

  // Workspace manifest: auto-loaded, replaceable on reload.
  let manifest: Disposable | undefined
  const loadManifest = async () => {
    const folders = vscode.workspace.workspaceFolders
    if (!folders) return
    const uri = vscode.Uri.joinPath(folders[0].uri, manifestPath())
    try {
      const values = await readDocument(uri)
      manifest?.dispose()
      manifest = provider.load(values)
    } catch {
      // No manifest (or unreadable): leave the built-ins as the surface.
    }
  }
  void loadManifest()

  registerDiagnostics(context)

  context.subscriptions.push(
    registerFormatter(),
    registerCodeLens(provider),
    registerSemanticTokens(),
    completion,

    vscode.commands.registerCommand('bassline.format', () =>
      provider.get('format')?.run(ctx())
    ),
    vscode.commands.registerCommand('bassline.evaluate', () =>
      provider.get('evaluate')?.run(ctx())
    ),

    // Evaluate a single `(borth …)` block at a source offset (per-block CodeLens).
    vscode.commands.registerCommand(
      'bassline.evaluateBlock',
      async (uriString: string, start: number) => {
        const doc =
          vscode.workspace.textDocuments.find(
            d => d.uri.toString() === uriString
          ) ?? vscode.window.activeTextEditor?.document
        if (doc) await evaluateBlockAt(doc, start)
      }
    ),

    // Run the directive at a given source offset (used by per-form CodeLens).
    // Re-reads the document and resolves statelessly — no closure is serialized.
    vscode.commands.registerCommand(
      'bassline.runDirective',
      async (uriString: string, start: number) => {
        const doc =
          vscode.workspace.textDocuments.find(
            d => d.uri.toString() === uriString
          ) ?? vscode.window.activeTextEditor?.document
        if (!doc) return
        let spans
        try {
          spans = readSpans(doc.getText())
        } catch {
          return
        }
        const span = spans.find(s => s.start === start)
        if (!span) return
        await provider.resolve(span.value)?.run({ document: doc })
      }
    ),

    // Run QuickPick over every affordance the provider currently exposes.
    vscode.commands.registerCommand('bassline.run', async () => {
      const items = provider
        .list()
        .map(a => ({ label: a.title, description: a.name, name: a.name }))
      const choice = await vscode.window.showQuickPick(items, {
        placeHolder: 'Bassline: run command',
      })
      if (choice) await provider.get(choice.name)?.run(ctx())
    }),

    // Fold an arbitrary document's affordances into the live provider.
    vscode.commands.registerCommand('bassline.loadAffordances', async () => {
      const picked = await vscode.window.showOpenDialog({
        canSelectMany: false,
        filters: { Bassline: ['blt'] },
      })
      if (!picked?.length) return
      try {
        const values = await readDocument(picked[0])
        provider.load(values)
        vscode.window.showInformationMessage('Bassline: affordances loaded.')
      } catch (e) {
        vscode.window.showErrorMessage(`Bassline load: ${String(e)}`)
      }
    }),

    vscode.commands.registerCommand('bassline.reloadManifest', () =>
      loadManifest()
    ),

    vscode.commands.registerCommand(
      'bassline.slurpForward',
      paredit(slurpForward)
    ),
    vscode.commands.registerCommand(
      'bassline.barfForward',
      paredit(barfForward)
    ),
    vscode.commands.registerCommand(
      'bassline.slurpBackward',
      paredit(slurpBackward)
    ),
    vscode.commands.registerCommand(
      'bassline.barfBackward',
      paredit(barfBackward)
    ),

    // Reload when the manifest itself is saved.
    vscode.workspace.onDidSaveTextDocument(doc => {
      if (doc.uri.path.endsWith(manifestPath())) void loadManifest()
    })
  )
}

export function deactivate(): void {}
