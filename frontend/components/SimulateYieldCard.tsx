"use client";

import { usePublicClient, useReadContracts, useWriteContract } from "wagmi";
import { formatEther, type Address } from "viem";
import { useState } from "react";
import { backstopHookAbi, yieldVaultAbi } from "@/lib/abis/backstopHook";
import { CONTRACTS } from "@/lib/contracts";

const YIELD_BPS = 500n; // 5% per click

type Busy = "idle" | "sweeping" | "yieldingUSDC" | "yieldingWETH";

export function SimulateYieldCard() {
  const publicClient = usePublicClient();
  const { writeContractAsync } = useWriteContract();
  const [busy, setBusy] = useState<Busy>("idle");

  const { data, refetch } = useReadContracts({
    contracts: [
      { address: CONTRACTS.usdcVault, abi: yieldVaultAbi, functionName: "totalAssets" },
      { address: CONTRACTS.wethVault, abi: yieldVaultAbi, functionName: "totalAssets" },
      { address: CONTRACTS.hook, abi: backstopHookAbi, functionName: "getReserveComposition", args: [CONTRACTS.usdc] },
      { address: CONTRACTS.hook, abi: backstopHookAbi, functionName: "getReserveComposition", args: [CONTRACTS.weth] },
      { address: CONTRACTS.hook, abi: backstopHookAbi, functionName: "pendingUSDC" },
      { address: CONTRACTS.hook, abi: backstopHookAbi, functionName: "pendingWETH" },
    ],
  });

  const usdcVaultTotal = (data?.[0]?.result as bigint | undefined) ?? 0n;
  const wethVaultTotal = (data?.[1]?.result as bigint | undefined) ?? 0n;
  const usdcReserve = data?.[2]?.result as [bigint, bigint, bigint] | undefined;
  const wethReserve = data?.[3]?.result as [bigint, bigint, bigint] | undefined;
  const pendingUSDC = (data?.[4]?.result as bigint | undefined) ?? 0n;
  const pendingWETH = (data?.[5]?.result as bigint | undefined) ?? 0n;

  const hookOwnsUSDCVault = usdcReserve?.[1] ?? 0n;
  const hookOwnsWETHVault = wethReserve?.[1] ?? 0n;

  async function onSweep() {
    if (!publicClient) return;
    try {
      setBusy("sweeping");
      const hash = await writeContractAsync({
        address: CONTRACTS.hook,
        abi: backstopHookAbi,
        functionName: "sweepToVaults",
      });
      await publicClient.waitForTransactionReceipt({ hash });
      refetch();
    } finally {
      setBusy("idle");
    }
  }

  async function onSimulate(vault: Address, which: "yieldingUSDC" | "yieldingWETH") {
    if (!publicClient) return;
    try {
      setBusy(which);
      const hash = await writeContractAsync({
        address: vault,
        abi: yieldVaultAbi,
        functionName: "simulateYield",
        args: [YIELD_BPS],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      refetch();
    } finally {
      setBusy("idle");
    }
  }

  const hasPending = pendingUSDC > 0n || pendingWETH > 0n;

  return (
    <div className="card card--accent faucet-card">
      <div className="sec-label sec-label--accent">Simulate Vault Yield</div>
      <p className="card-lede">
        The mock vaults don't auto-yield. To make yield visible to underwriters:
        (1) sweep pending premium into the vaults, then (2) mint +5% into each vault.
        Both steps below. In production, Chainlink Automation would periodically sweep.
      </p>

      <div className="inner-panel">
        <div className="inner-panel-head">
          <span className="inner-step">1. Sweep pending into vaults</span>
          <button
            type="button"
            className="btn btn--accent btn--sm"
            onClick={onSweep}
            disabled={busy !== "idle"}
          >
            {busy === "sweeping" ? "Sweeping…" : "Sweep now"}
          </button>
        </div>
        <div className="pending-row">
          <div className="pending-item">
            pending USDC: <span className="mono strong">{formatEther(pendingUSDC)}</span>
          </div>
          <div className="pending-item">
            pending WETH: <span className="mono strong">{formatEther(pendingWETH)}</span>
          </div>
        </div>
        {!hasPending && (
          <div className="hint-warn">
            no pending premium — run a swap first (or sweep is a no-op).
          </div>
        )}
      </div>

      <div className="dual-grid vault-grid">
        <VaultCol
          label="2a. +5% USDC vault"
          totalAssets={usdcVaultTotal}
          hookOwns={hookOwnsUSDCVault}
          busy={busy === "yieldingUSDC"}
          disabled={busy !== "idle"}
          onClick={() => onSimulate(CONTRACTS.usdcVault, "yieldingUSDC")}
        />
        <VaultCol
          label="2b. +5% WETH vault"
          totalAssets={wethVaultTotal}
          hookOwns={hookOwnsWETHVault}
          busy={busy === "yieldingWETH"}
          disabled={busy !== "idle"}
          onClick={() => onSimulate(CONTRACTS.wethVault, "yieldingWETH")}
        />
      </div>
    </div>
  );
}

function VaultCol({
  label,
  totalAssets,
  hookOwns,
  busy,
  disabled,
  onClick,
}: {
  label: string;
  totalAssets: bigint;
  hookOwns: bigint;
  busy: boolean;
  disabled: boolean;
  onClick: () => void;
}) {
  const isUseless = hookOwns === 0n;
  return (
    <div className="vault-col">
      <button
        type="button"
        className="btn btn--accent-soft"
        onClick={onClick}
        disabled={disabled}
      >
        {busy ? "Yielding…" : label}
      </button>
      <div className="vault-meta">
        <div>
          vault total: <span className="mono">{formatEther(totalAssets)}</span>
        </div>
        <div>
          hook owns: <span className="mono">{formatEther(hookOwns)}</span>
        </div>
        {isUseless && (
          <div className="vault-meta-warn">click sweep above first ↑</div>
        )}
      </div>
    </div>
  );
}
