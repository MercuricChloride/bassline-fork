import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // Tests live in test/ and exercise the pure pieces (provider + directive
    // recognition) that do not touch the VS Code runtime.
    include: ['test/**/*.test.ts'],
  },
})
