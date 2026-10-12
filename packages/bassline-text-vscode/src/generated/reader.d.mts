// Types for reader.mjs, built from petit-parser's src/petit_parser/js.nim
// by `pnpm reader`.
export type BlKind =
  | 'nil' | 'int' | 'text' | 'symbol' | 'bytes' | 'list' | 'record' | 'set' | 'dict'

export interface BlValue {
  kind: BlKind
  mark?: true
  text?: string
  bytes?: Uint8Array
  items?: BlValue[]
  entries?: [BlValue, BlValue][]
  /** Offsets into the text, on top level values. */
  start?: number
  stop?: number
}

export type ReadResult =
  | { values: BlValue[]; error?: undefined }
  | { error: string; offset: number; line: number; column: number; values?: undefined }

export function parseBassline(text: string): ReadResult
