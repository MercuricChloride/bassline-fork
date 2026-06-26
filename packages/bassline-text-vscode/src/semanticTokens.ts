// Reader-backed semantic tokens: readSpans sees structure the TextMate grammar
// can't, so we color each `<comment "…">` directive as a comment. Extend with a
// new token type in the legend and another span pass.
import * as vscode from 'vscode'
import { readSpans } from '@bassline/core/text'
import { isComment } from './directives'

export const legend = new vscode.SemanticTokensLegend(['comment'])
const COMMENT = 0 // index into legend.tokenTypes

/** Emit a token spanning `[start, end)`, split per line (tokens are single-line). */
function markRange(
  builder: vscode.SemanticTokensBuilder,
  doc: vscode.TextDocument,
  start: vscode.Position,
  end: vscode.Position,
  tokenType: number
): void {
  for (let line = start.line; line <= end.line; line++) {
    const from = line === start.line ? start.character : 0
    const to = line === end.line ? end.character : doc.lineAt(line).text.length
    if (to > from) builder.push(line, from, to - from, tokenType)
  }
}

export function registerSemanticTokens(): vscode.Disposable {
  return vscode.languages.registerDocumentSemanticTokensProvider(
    'bassline-text',
    {
      provideDocumentSemanticTokens(doc) {
        const builder = new vscode.SemanticTokensBuilder(legend)
        let spans
        try {
          spans = readSpans(doc.getText())
        } catch {
          return builder.build()
        }
        for (const s of spans) {
          if (!isComment(s.value)) continue
          markRange(
            builder,
            doc,
            doc.positionAt(s.start),
            doc.positionAt(s.end),
            COMMENT
          )
        }
        return builder.build()
      },
    },
    legend
  )
}
