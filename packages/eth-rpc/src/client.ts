import { msg } from '@bassline/core'
import type {
  Address,
  Block,
  BlockNumberOrTag,
  Bytes,
  Hash,
  Quantity,
  Transaction,
} from './types/index.js'
import type { EthRpcMethods } from './types/methods.js'
import { defineMenu, type Menu } from './menu.js'
import type { Send } from '@bassline/core'
import type { Request as MenuRequest } from './menu.js'

export type ClientOpts = {
  url: string
  fetch?: typeof fetch
  headers?: HeadersInit
}

export type Request = {
  (
    method: 'eth_getBlockByHash',
    hash: Hash,
    fullTransactions: true
  ): Promise<Block<Transaction> | null>
  (
    method: 'eth_getBlockByHash',
    hash: Hash,
    fullTransactions: false
  ): Promise<Block<Hash> | null>
  (
    method: 'eth_getBlockByNumber',
    tag: BlockNumberOrTag,
    fullTransactions: true
  ): Promise<Block<Transaction> | null>
  (
    method: 'eth_getBlockByNumber',
    tag: BlockNumberOrTag,
    fullTransactions: false
  ): Promise<Block<Hash> | null>
  <M extends keyof EthRpcMethods>(
    method: M,
    ...params: EthRpcMethods[M]['params']
  ): Promise<EthRpcMethods[M]['result']>
}

export type AddressAtBlockData = {
  address: Address
  block: BlockNumberOrTag
}

export type AddressAtBlockMenu = Menu<
  AddressAtBlockData,
  {
    balance: Send<MenuRequest>
    code: Send<MenuRequest>
    nonce: Send<MenuRequest>
  }
>

export type Client = {
  request: Request
  addressAt: (address: Address, block: BlockNumberOrTag) => AddressAtBlockMenu
}

type RpcError = { code: number; message: string; data?: unknown }
type RpcResponse = { result?: unknown; error?: RpcError }

export class JsonRpcError extends Error {
  readonly code: number
  readonly data?: unknown
  constructor(code: number, message: string, data?: unknown) {
    super(message)
    this.name = 'JsonRpcError'
    this.code = code
    this.data = data
  }
}

export function createClient(opts: ClientOpts): Client {
  const f = opts.fetch ?? fetch
  let id = 0

  const request = (async (method: string, ...params: unknown[]) => {
    const headers = new Headers(opts.headers)
    if (!headers.has('content-type'))
      headers.set('content-type', 'application/json')
    const body = JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params })
    const res = await f(opts.url, { method: 'POST', headers, body })
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
    const json = (await res.json()) as RpcResponse
    if (json.error)
      throw new JsonRpcError(
        json.error.code,
        json.error.message,
        json.error.data
      )
    return json.result
  }) as Request

  const AddressAtBlock = defineMenu<AddressAtBlockData>()
    .verb('balance', async (m) => {
      const value: Quantity = await request(
        'eth_getBalance',
        m.data.address,
        m.data.block,
      )
      return msg({ value })
    })
    .verb('code', async (m) => {
      const value: Bytes = await request(
        'eth_getCode',
        m.data.address,
        m.data.block,
      )
      return msg({ value })
    })
    .verb('nonce', async (m) => {
      const value: Quantity = await request(
        'eth_getTransactionCount',
        m.data.address,
        m.data.block,
      )
      return msg({ value })
    })

  const addressAt = (address: Address, block: BlockNumberOrTag) =>
    AddressAtBlock.from({ address, block })

  return { request, addressAt }
}
