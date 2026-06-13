import type { Address, Bytes, Hash, Hex, Quantity } from './hex.js'
import type { Log } from './log.js'

export type TransactionReceipt = {
  blockHash: Hash
  blockNumber: Quantity
  transactionHash: Hash
  transactionIndex: Quantity
  from: Address
  to: Address | null
  cumulativeGasUsed: Quantity
  gasUsed: Quantity
  effectiveGasPrice: Quantity
  logs: Log[]
  logsBloom: Bytes
  type?: Hex
  contractAddress?: Address | null
  blobGasUsed?: Quantity
  blobGasPrice?: Quantity
  root?: Hash
  status?: '0x0' | '0x1'
}
