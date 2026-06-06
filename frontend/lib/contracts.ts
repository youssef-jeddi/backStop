import type { Address } from "viem";

/**
 * Contract addresses pulled from env. Set these in `.env.local` after running
 * `forge script script/DeployBackstop.s.sol` — the script logs all addresses
 * at the end of its output.
 */
export const CONTRACTS = {
  hook: (process.env.NEXT_PUBLIC_HOOK_ADDRESS as Address) ?? "0x0000000000000000000000000000000000000000",
  usdc: (process.env.NEXT_PUBLIC_USDC_ADDRESS as Address) ?? "0x0000000000000000000000000000000000000000",
  weth: (process.env.NEXT_PUBLIC_WETH_ADDRESS as Address) ?? "0x0000000000000000000000000000000000000000",
  usdcVault: (process.env.NEXT_PUBLIC_USDC_VAULT_ADDRESS as Address) ?? "0x0000000000000000000000000000000000000000",
  wethVault: (process.env.NEXT_PUBLIC_WETH_VAULT_ADDRESS as Address) ?? "0x0000000000000000000000000000000000000000",
} as const;
