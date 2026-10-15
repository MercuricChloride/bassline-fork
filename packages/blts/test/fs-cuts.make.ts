// Writes fs-cuts.bl: for each input, the content blnim's fs.nim makes of it,
// (cut CONTENT-DIGEST [CHUNK-DIGEST …]), so fs.test.ts can check that TS cuts
// in the same places and digests the same content. Run with the fscuts
// program built from packages/blnim/tests/fscuts.nim:
//
//   (cd ../blnim && nim c -o:/tmp/fscuts tests/fscuts.nim)
//   node test/fs-cuts.make.ts /tmp/fscuts

import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { inputs } from './fs-inputs.ts'

const fscuts = process.argv[2]
if (!fscuts) throw new Error('usage: node test/fs-cuts.make.ts FSCUTS')
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fs-cuts-'))
for (const [name, data] of Object.entries(inputs))
  fs.writeFileSync(path.join(dir, name), data)
const cut = execFileSync(fscuts, [dir], { encoding: 'utf8' })
fs.writeFileSync(
  new URL('fs-cuts.bl', import.meta.url),
  '; made by fs-cuts.make.ts: each input, and the content fs.nim makes of it\n' +
    cut
)
fs.rmSync(dir, { recursive: true })
