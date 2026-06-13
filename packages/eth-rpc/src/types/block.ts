import type { Address, Bytes, Hash, Quantity } from './hex.js'
import type { Transaction } from './transaction.js'

export type Withdrawal = {
  index: Quantity
  validatorIndex: Quantity
  address: Address
  amount: Quantity
}

export type Block<TTx = Hash | Transaction> = {
  hash: Hash
  parentHash: Hash
  sha3Uncles: Hash
  miner: Address
  stateRoot: Hash
  transactionsRoot: Hash
  receiptsRoot: Hash
  logsBloom: Bytes
  number: Quantity
  gasLimit: Quantity
  gasUsed: Quantity
  timestamp: Quantity
  extraData: Bytes
  mixHash: Hash
  nonce: Bytes
  size: Quantity
  transactions: TTx[]
  uncles: Hash[]
  difficulty?: Quantity
  totalDifficulty?: Quantity
  baseFeePerGas?: Quantity
  withdrawalsRoot?: Hash
  withdrawals?: Withdrawal[]
  blobGasUsed?: Quantity
  excessBlobGas?: Quantity
  parentBeaconBlockRoot?: Hash
}

export type BlockOverrides = {
  number?: Quantity
  prevRandao?: Hash
  time?: Quantity
  gasLimit?: Quantity
  feeRecipient?: Address
  baseFeePerGas?: Quantity
  blobBaseFee?: Quantity
  withdrawals?: Withdrawal[]
}
