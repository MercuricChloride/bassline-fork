import type { Address, Bytes, Hash, Quantity, BlockNumberOrTag } from './hex.js'

export type Log = {
  removed: boolean
  logIndex: Quantity | null
  transactionIndex: Quantity | null
  transactionHash: Hash | null
  blockHash: Hash | null
  blockNumber: Quantity | null
  address: Address
  data: Bytes
  topics: Hash[]
}

export type FilterTopic = Hash | Hash[] | null

export type FilterOptions = {
  fromBlock?: BlockNumberOrTag
  toBlock?: BlockNumberOrTag
  address?: Address | Address[]
  topics?: FilterTopic[]
  blockHash?: Hash
}
