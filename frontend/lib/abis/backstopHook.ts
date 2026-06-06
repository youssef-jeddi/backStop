/**
 * Hand-picked ABI fragments the underwriter dashboard needs to call.
 *
 * For full coverage (e.g. listening to events), generate the full ABI from
 * forge artifacts: `forge inspect src/BackstopHook.sol:BackstopHook abi`
 * and paste, or wire up `@wagmi/cli` with the foundry plugin.
 */
export const backstopHookAbi = [
  // ── Underwriter ops ──────────────────────────────────────────────────────
  {
    type: "function",
    name: "depositAsUnderwriter",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
  },
  {
    type: "function",
    name: "withdrawAsUnderwriter",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "shares", type: "uint256" },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
  {
    type: "function",
    name: "sweepToVaults",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },

  // ── Views ────────────────────────────────────────────────────────────────
  {
    type: "function",
    name: "getCurrentVolatility",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "getCurrentPremiumRate",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "getReserveComposition",
    stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [
      { name: "buffer", type: "uint256" },
      { name: "vaultAssets", type: "uint256" },
      { name: "totalShares", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "getUnderwriterShares",
    stateMutability: "view",
    inputs: [
      { name: "user", type: "address" },
      { name: "token", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "getUnderwriterAPYBreakdown",
    stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [
      { name: "premiumAPY", type: "uint256" },
      { name: "vaultAPY", type: "uint256" },
      { name: "claimDragBps", type: "uint256" },
      { name: "netAPY", type: "int256" },
    ],
  },

  // Pending counters (public state vars → auto-generated getters).
  {
    type: "function",
    name: "pendingUSDC",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "pendingWETH",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },

  // Lifetime stats (public state vars → auto-generated getters).
  {
    type: "function",
    name: "totalPremiumsAccumulatedUSDC",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "totalPremiumsAccumulatedWETH",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "totalClaimsPaidUSDC",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "totalClaimsPaidWETH",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "poolStartTimestamp",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
] as const;

// Yield-vault ABI — only the bits the demo needs (simulateYield + totalAssets).
export const yieldVaultAbi = [
  {
    type: "function",
    name: "simulateYield",
    stateMutability: "nonpayable",
    inputs: [{ name: "basisPoints", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "totalAssets",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
] as const;

// Minimal ERC20 fragments for approval + balance reads on the underlying tokens.
// `mint` is solmate MockERC20's public faucet — only present on demo tokens.
export const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
] as const;
