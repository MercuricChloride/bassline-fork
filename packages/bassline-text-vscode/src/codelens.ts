// CodeLens: two document-level actions (Run…, Format) at the top, plus a lens at
// each recognized directive's span. The lens calls `bassline.runDirective` with
// the form's start offset, which re-resolves it statelessly.
import * as vscode from 'vscode'
import { readSpans } from '@bassline/core/text'
import type { Affordances } from './affordances'
import { isDirective } from './directives'

export function registerCodeLens(provider: Affordances): vscode.Disposable {
  return vscode.languages.registerCodeLensProvider('bassline-text', {
    provideCodeLenses(doc) {
      const top = new vscode.Range(0, 0, 0, 0)
      const lenses: vscode.CodeLens[] = [
        new vscode.CodeLens(top, { title: '⚙ Run…', command: 'bassline.run' }),
        new vscode.CodeLens(top, {
          title: '✎ Format',
          command: 'bassline.format',
        }),
      ]

      let spans
      try {
        spans = readSpans(doc.getText())
      } catch {
        return lenses // unparseable: diagnostics will show why
      }

      for (const s of spans) {
        if (!isDirective(s.value)) continue
        const aff = provider.resolve(s.value)
        if (!aff) continue
        const pos = doc.positionAt(s.start)
        lenses.push(
          new vscode.CodeLens(new vscode.Range(pos, pos), {
            title: `▶ ${aff.title}`,
            command: 'bassline.runDirective',
            arguments: [doc.uri.toString(), s.start],
          })
        )
      }
      return lenses
    },
  })
}
