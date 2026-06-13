import type { Address, Bytes, Hash, Hex, Quantity } from './hex.js'

export type AccessListEntry = {
  address: Address
  storageKeys: Hash[]
}

export type Authorization = {
  chainId: Quantity
  address: Address
  nonce: Quantity
  yParity: Quantity
  r: Hash
  s: Hash
}

type TxBase = {
  blockHash: Hash | null
  blockNumber: Quantity | null
  transactionIndex: Quantity | null
  hash: Hash
  from: Address
  to: Address | null
  nonce: Quantity
  gas: Quantity
  value: Quantity
  input: Bytes
  chainId?: Quantity
  v?: Quantity
  r: Hash
  s: Hash
  yParity?: Quantity
}

type Tx1559Fields = TxBase & {
  maxFeePerGas: Quantity
  maxPriorityFeePerGas: Quantity
  accessList: AccessListEntry[]
  yParity: Quantity
  gasPrice?: Quantity
}

export type LegacyTx = TxBase & {
  type?: '0x0'
  gasPrice: Quantity
}

export type Tx2930 = TxBase & {
  type: '0x1'
  gasPrice: Quantity
  accessList: AccessListEntry[]
  yParity: Quantity
}

export type Tx1559 = Tx1559Fields & {
  type: '0x2'
}

export type Tx4844 = Tx1559Fields & {
  type: '0x3'
  to: Address
  maxFeePerBlobGas: Quantity
  blobVersionedHashes: Hash[]
}

export type Tx7702 = Tx1559Fields & {
  type: '0x4'
  to: Address
  authorizationList: Authorization[]
}

export type Transaction = LegacyTx | Tx2930 | Tx1559 | Tx4844 | Tx7702

export type TransactionRequest = {
  from?: Address
  to?: Address | null
  gas?: Quantity
  gasPrice?: Quantity
  maxFeePerGas?: Quantity
  maxPriorityFeePerGas?: Quantity
  maxFeePerBlobGas?: Quantity
  value?: Quantity
  input?: Bytes
  data?: Bytes
  nonce?: Quantity
  type?: Hex
  chainId?: Quantity
  accessList?: AccessListEntry[]
  blobVersionedHashes?: Hash[]
  authorizationList?: Authorization[]
}
