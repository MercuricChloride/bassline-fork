export type Hex = `0x${string}`

export type Quantity = Hex
export type Bytes = Hex
export type Address = Hex
export type Hash = Hex

export type BlockTag = 'latest' | 'earliest' | 'pending' | 'safe' | 'finalized'
export type BlockNumberOrTag = Quantity | BlockTag
export type BlockNumberOrHash = BlockNumberOrTag | Hash
