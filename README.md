# ☂️ BackStop

> A two-sided impermanent loss insurance marketplace built as a Uniswap v4 hook.
> Aave Umbrella, for impermanent loss.

![CI](https://github.com/youssef-jeddi/backstop/actions/workflows/test.yml/badge.svg) 
[![codecov](https://codecov.io/gh/youssef-jeddi/backstop/branch/main/graph/badge.svg)](https://codecov.io/gh/youssef-jeddi/backstop)

Built for the **UHI9 Hookathon**. **Cohort theme**: _Impermanent Loss & Yield Systems_. **No partner integrations**

---

## What BackStop is

LP on a v4 pool with the BackStop hook attached and you're automatically insured against impermanent loss. A small share of your swap fees (5–30%, dynamic) is rerouted to a pool of underwriters who fund the insurance reserve. When you withdraw with realized IL above a threshold, the hook computes your loss and pays it back from that reserve.

- **Trader** pays the same 0.30% total fee as any normal pool.
- **LP** gets slightly less fee yield in exchange for automatic IL protection.
- **Underwriter** earns the rerouted fees + vault yield, takes losses when IL claims fire.

No oracle, no admin, no governance. The pool's own swap activity sets its own insurance premium cost via a self-pricing premium curve.

---

## 🚀 Live on Sepolia

| Contract | Address |
|---|---|
| BackstopHook | [`0xec052f9f87e8974c1fe6e590922ac3f5603905c4`](https://sepolia.etherscan.io/address/0xec052f9f87e8974c1fe6e590922ac3f5603905c4) |
| Mock USDC | [`0xf2c0d775d81c581af6260647f939fae603c3b713`](https://sepolia.etherscan.io/address/0xf2c0d775d81c581af6260647f939fae603c3b713) |
| Mock WETH | [`0xef8ac3f474112c277de561ceff8f7474ef41084d`](https://sepolia.etherscan.io/address/0xef8ac3f474112c277de561ceff8f7474ef41084d) |
| MockUSDCVault | [`0x45ce2609449d35204b7c00fe412c87a78e3f6dc1`](https://sepolia.etherscan.io/address/0x45ce2609449d35204b7c00fe412c87a78e3f6dc1) |
| MockWETHVault | [`0x6f7461bcc3ddbd5fc1666bd71a8a414d84ce7fc1`](https://sepolia.etherscan.io/address/0x6f7461bcc3ddbd5fc1666bd71a8a414d84ce7fc1) |

PoolManager is canonical Sepolia v4 (`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`). Pool is USDC/WETH with `DYNAMIC_FEE_FLAG`.

---

## ✨ Key mechanics

- **Convex premium curve** (`premium ∝ vol²`) on realized volatility from a 16-slot sqrt-price observation buffer. Floors at 5%, saturates at 30%. Matches the σ²-shape of expected IL under GBM.
- **Dynamic LP fee + return-delta routing.** Per swap, `beforeSwap` overrides the LP fee to `TARGET × (1 − premiumRate)`; `afterSwap` claims the missing slice as a hookDelta on the unspecified currency and `take()`s it from the PoolManager. Trader's total fee stays constant at 0.30%.
- **80/20 buffer/vault split.** Underwriter capital sits 20% liquid in the hook (instant claim payouts) and 80% in a yield vault. Enforced on every deposit (not just sweep) so principal earns vault yield from day 1.
- **Closed-form IL.** Computed at `afterRemoveLiquidity` from the LP's entry vs current sqrt-price using the [**FullMath**](https://github.com/Uniswap/v4-core/blob/main/src/libraries/FullMath.sol) uniswap library. No oracle, no integration.
- **Share-based underwriter accounting** (ERC4626-style). Each side priced against per-side NAV (buffer + hook's claim on the vault). Auto-sweep on every deposit/withdraw keeps NAV current.
- **5 hook permission flags.** `afterAdd`, `afterRemove`, `beforeSwap`, `afterSwap`, `afterSwapReturnDelta`.

---

## 🏗️ Build & test

Foundry-based contracts in `contracts/`.

```bash
cd contracts
forge build
forge test
```

Full test suite: 78 unit tests + 1 end-to-end integration test (`BackstopDemo.t.sol`) covering deploy/permissions, volatility math, swap accrual, underwriter ops, entry tracking, IL math, IL payout, view surface, and a full lifecycle scenario.

```bash
forge test --mc BackstopDemo -vvv   # narrative end-to-end demo
```

### Coverage (`forge coverage`)

Run `forge coverage` locally to verify. Snapshot from latest build:

| File | Lines | Statements | Branches | Funcs |
|---|---:|---:|---:|---:|
| `src/BackstopHook.sol` | 94.59% (297/314) | 90.96% (342/376) | 71.64% (48/67) | 100% (35/35) |
| `src/libraries/ILMath.sol` | 100% (13/13) | 100% (23/23) | 100% (2/2) | 100% (1/1) |
| `src/vaults/MockUSDCVault.sol` | 100% (25/25) | 100% (27/27) | 100% (4/4) | 100% (5/5) |
| `src/vaults/MockWETHVault.sol` | 100% (25/25) | 100% (27/27) | 100% (4/4) | 100% (5/5) |

---

## 💻 Run the frontend

```bash
cd frontend
cp .env.local.example .env.local
# fill in: NEXT_PUBLIC_WC_PROJECT_ID, NEXT_PUBLIC_SEPOLIA_RPC_URL,
#         and the five NEXT_PUBLIC_*_ADDRESS entries from the table above
npm install
npm run dev
```

Open `http://localhost:3000`, connect a Sepolia wallet, deposit as an underwriter. The `/faucet` route mints mock tokens and triggers synthetic vault yield for demo purposes.

---

## 📜 License
MIT
