import * as esbuild from 'esbuild'

const watch = process.argv.includes('--watch')

/** @type {import('esbuild').BuildOptions} */
const options = {
  entryPoints: ['src/extension.ts'],
  bundle: true,
  format: 'cjs',
  platform: 'node',
  target: 'node20',
  // The VS Code API is provided by the host at runtime, never bundled.
  external: ['vscode'],
  // @bassline/core and @bassline/comm are ESM workspace packages; bundling
  // inlines them into the single CJS output so the packaged .vsix needs no
  // node_modules resolution at runtime.
  outfile: 'dist/extension.js',
  sourcemap: true,
  logLevel: 'info',
}

if (watch) {
  const ctx = await esbuild.context(options)
  await ctx.watch()
  console.log('esbuild: watching…')
} else {
  await esbuild.build(options)
}
