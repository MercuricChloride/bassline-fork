import type { Quantity } from './hex.js'

export type FeeHistoryResult = {
  oldestBlock: Quantity
  baseFeePerGas: Quantity[]
  gasUsedRatio: number[]
  reward?: Quantity[][]
  baseFeePerBlobGas?: Quantity[]
  blobGasUsedRatio?: number[]
}

export type SyncingStatus =
  | false
  | {
      startingBlock: Quantity
      currentBlock: Quantity
      highestBlock: Quantity
      knownStates?: Quantity
      pulledStates?: Quantity
    }
