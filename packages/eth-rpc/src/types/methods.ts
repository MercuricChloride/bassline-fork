import type {
  AccessListEntry,
  Address,
  Block,
  BlockNumberOrTag,
  BlockOverrides,
  Bytes,
  FeeHistoryResult,
  FilterOptions,
  Hash,
  Log,
  Quantity,
  StateOverrideSet,
  SyncingStatus,
  Transaction,
  TransactionReceipt,
  TransactionRequest,
} from './index.js'

export interface EthRpcMethods {
  web3_clientVersion: { params: []; result: string }
  web3_sha3: { params: [Bytes]; result: Hash }

  net_version: { params: []; result: string }
  net_listening: { params: []; result: boolean }
  net_peerCount: { params: []; result: Quantity }

  eth_protocolVersion: { params: []; result: Quantity }
  eth_chainId: { params: []; result: Quantity }
  eth_blockNumber: { params: []; result: Quantity }
  eth_gasPrice: { params: []; result: Quantity }
  eth_maxPriorityFeePerGas: { params: []; result: Quantity }
  eth_accounts: { params: []; result: Address[] }
  eth_syncing: { params: []; result: SyncingStatus }
  eth_coinbase: { params: []; result: Address | null }

  eth_getBalance: { params: [Address, BlockNumberOrTag]; result: Quantity }
  eth_getStorageAt: {
    params: [Address, Quantity, BlockNumberOrTag]
    result: Hash
  }
  eth_getCode: { params: [Address, BlockNumberOrTag]; result: Bytes }
  eth_getTransactionCount: {
    params: [Address, BlockNumberOrTag]
    result: Quantity
  }

  eth_getBlockTransactionCountByHash: {
    params: [Hash]
    result: Quantity | null
  }
  eth_getBlockTransactionCountByNumber: {
    params: [BlockNumberOrTag]
    result: Quantity | null
  }

  eth_getBlockByHash: {
    params: [Hash, boolean]
    result: Block | null
  }
  eth_getBlockByNumber: {
    params: [BlockNumberOrTag, boolean]
    result: Block | null
  }

  eth_getTransactionByHash: { params: [Hash]; result: Transaction | null }
  eth_getTransactionByBlockHashAndIndex: {
    params: [Hash, Quantity]
    result: Transaction | null
  }
  eth_getTransactionByBlockNumberAndIndex: {
    params: [BlockNumberOrTag, Quantity]
    result: Transaction | null
  }

  eth_getTransactionReceipt: {
    params: [Hash]
    result: TransactionReceipt | null
  }
  eth_getBlockReceipts: {
    params: [BlockNumberOrTag]
    result: TransactionReceipt[] | null
  }

  eth_call: {
    params: [
      TransactionRequest,
      BlockNumberOrTag,
      StateOverrideSet?,
      BlockOverrides?,
    ]
    result: Bytes
  }
  eth_estimateGas: {
    params: [TransactionRequest, BlockNumberOrTag?]
    result: Quantity
  }
  eth_createAccessList: {
    params: [TransactionRequest, BlockNumberOrTag?]
    result: {
      accessList: AccessListEntry[]
      gasUsed: Quantity
      error?: string
    }
  }

  eth_sendRawTransaction: { params: [Bytes]; result: Hash }

  eth_newFilter: { params: [FilterOptions]; result: Quantity }
  eth_newBlockFilter: { params: []; result: Quantity }
  eth_newPendingTransactionFilter: { params: []; result: Quantity }
  eth_uninstallFilter: { params: [Quantity]; result: boolean }
  eth_getFilterChanges: { params: [Quantity]; result: Hash[] | Log[] }
  eth_getFilterLogs: { params: [Quantity]; result: Log[] }
  eth_getLogs: { params: [FilterOptions]; result: Log[] }

  eth_feeHistory: {
    params: [Quantity, BlockNumberOrTag, number[]?]
    result: FeeHistoryResult
  }
}
