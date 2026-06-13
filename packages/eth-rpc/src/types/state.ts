import type { Address, Bytes, Hash, Quantity } from './hex.js'

export type AccountOverride = {
  balance?: Quantity
  nonce?: Quantity
  code?: Bytes
  state?: Record<Hash, Hash>
  stateDiff?: Record<Hash, Hash>
  movePrecompileToAddress?: Address
}

export type StateOverrideSet = Record<Address, AccountOverride>
