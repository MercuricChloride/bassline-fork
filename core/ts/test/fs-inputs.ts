// Files the fs tests cut, made the same way every time, and the chunk digests
// blnim gives for them (fs-cuts.bl, made by fs-cuts.make.ts).

/** n bytes from a 64-bit LCG, its top byte each step. */
function lcg(seed: bigint, n: number) {
  const out = new Uint8Array(n)
  let x = seed
  for (let i = 0; i < n; i++) {
    x = (x * 6364136223846793005n + 1442695040888963407n) & ((1n << 64n) - 1n)
    out[i] = Number(x >> 56n)
  }
  return out
}

const enc = new TextEncoder()

export const inputs: Record<string, Uint8Array> = {
  'empty.bin': new Uint8Array(0),
  'small.txt': enc.encode('hello\n'),
  'inline-most.bin': lcg(1n, 65536),
  'one-past.bin': lcg(2n, 65537),
  'zeros.bin': new Uint8Array(200000),
  'text.txt': enc.encode(
    'the quick brown fox jumps over the lazy dog\n'.repeat(8000)
  ),
  'random.bin': lcg(12345n, 1 << 19),
}
