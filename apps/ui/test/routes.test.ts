import { describe, expect, it } from 'vitest'
import routes from '~/routes'

describe('routes', () => {
  it('should match the route config', () => {
    expect(routes).toEqual([
      { file: 'routes/home.tsx', index: true },
      { file: 'routes/document.tsx', path: 'document' },
    ])
  })
})
