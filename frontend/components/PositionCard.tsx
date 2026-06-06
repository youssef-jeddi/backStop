"use client";

import { useState } from "react";
import { useAccount, usePublicClient, useReadContracts, useWriteContract } from "wagmi";
import { formatEther, parseEther, type Address } from "viem";
import { backstopHookAbi, erc20Abi } from "@/lib/abis/backstopHook";
import { CONTRACTS } from "@/lib/contracts";

type Busy = "idle" | "approving" | "depositing" | "withdrawing";

export function PositionCard({ label, token }: { label: string; token: Address }) {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const { writeContractAsync } = useWriteContract();

  const [depositAmount, setDepositAmount] = useState("");
  const [withdrawShares, setWithdrawShares] = useState("");
  const [busy, setBusy] = useState<Busy>("idle");

  const premiumFn = label === "USDC" ? "totalPremiumsAccumulatedUSDC" : "totalPremiumsAccumulatedWETH";
  const claimsFn = label === "USDC" ? "totalClaimsPaidUSDC" : "totalClaimsPaidWETH";

  const { data, refetch } = useReadContracts({
    contracts: [
      {
        address: CONTRACTS.hook,
        abi: backstopHookAbi,
        functionName: "getReserveComposition",
        args: [token],
      },
      {
        address: CONTRACTS.hook,
        abi: backstopHookAbi,
        functionName: "getUnderwriterAPYBreakdown",
        args: [token],
      },
      {
        address: CONTRACTS.hook,
        abi: backstopHookAbi,
        functionName: "getUnderwriterShares",
        args: address ? [address, token] : ["0x0000000000000000000000000000000000000000" as Address, token],
      },
      {
        address: token,
        abi: erc20Abi,
        functionName: "allowance",
        args: address
          ? [address, CONTRACTS.hook]
          : ["0x0000000000000000000000000000000000000000" as Address, CONTRACTS.hook],
      },
      { address: CONTRACTS.hook, abi: backstopHookAbi, functionName: premiumFn },
      { address: CONTRACTS.hook, abi: backstopHookAbi, functionName: claimsFn },
    ],
  });

  const composition = data?.[0]?.result as [bigint, bigint, bigint] | undefined;
  const apy = data?.[1]?.result as [bigint, bigint, bigint, bigint] | undefined;
  const userShares = data?.[2]?.result as bigint | undefined;
  const allowance = data?.[3]?.result as bigint | undefined;
  const lifetimePremium = (data?.[4]?.result as bigint | undefined) ?? 0n;
  const lifetimeClaims = (data?.[5]?.result as bigint | undefined) ?? 0n;

  const premiumApy = apy?.[0] ?? 0n;
  const vaultApy = apy?.[1] ?? 0n;
  const claimDrag = apy?.[2] ?? 0n;

  const buffer = composition?.[0] ?? 0n;
  const vaultAssets = composition?.[1] ?? 0n;
  const totalShares = composition?.[2] ?? 0n;
  const nav = buffer + vaultAssets;
  const userValue = userShares !== undefined && totalShares > 0n ? (userShares * nav) / totalShares : 0n;
  const netApy = apy ? (apy[3] as unknown as bigint) : 0n;

  async function onDeposit() {
    if (!depositAmount || !address || !publicClient) return;
    const amountWei = parseEther(depositAmount);
    try {
      if (!allowance || allowance < amountWei) {
        setBusy("approving");
        const approveHash = await writeContractAsync({
          address: token,
          abi: erc20Abi,
          functionName: "approve",
          args: [CONTRACTS.hook, amountWei],
        });
        await publicClient.waitForTransactionReceipt({ hash: approveHash });
      }
      setBusy("depositing");
      const hash = await writeContractAsync({
        address: CONTRACTS.hook,
        abi: backstopHookAbi,
        functionName: "depositAsUnderwriter",
        args: [token, amountWei],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      setDepositAmount("");
      refetch();
    } finally {
      setBusy("idle");
    }
  }

  async function onWithdraw(useMax: boolean) {
    if (!address || !publicClient) return;
    const sharesWei = useMax ? (userShares ?? 0n) : withdrawShares ? parseEther(withdrawShares) : 0n;
    if (sharesWei === 0n) return;
    try {
      setBusy("withdrawing");
      const hash = await writeContractAsync({
        address: CONTRACTS.hook,
        abi: backstopHookAbi,
        functionName: "withdrawAsUnderwriter",
        args: [token, sharesWei],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      setWithdrawShares("");
      refetch();
    } finally {
      setBusy("idle");
    }
  }

  const depositLabel =
    busy === "approving"
      ? "Approving…"
      : busy === "depositing"
        ? "Depositing…"
        : `Deposit ${label}`;
  const withdrawLabel = busy === "withdrawing" ? "Withdrawing…" : "Withdraw";

  return (
    <div className="card pool-card">
      <div className="sec-label">{label} POOL</div>

      <div className="pool-topgrid">
        <Stat label="Pool NAV" value={fmt(nav)} unit={label} />
        <Stat label="Net APY" value={`${signedBpsToPct(netApy)}%`} tone="pos" />
        <Stat label="Your shares" value={fmt(userShares ?? 0n)} />
        <Stat label="Your value" value={fmt(userValue)} unit={label} />
      </div>

      <div className="metric-panel">
        <div className="metric-row metric-row--3">
          <Metric label="Premium APY" value={`${bpsToPct(premiumApy)}%`} />
          <Metric label="Vault APY" value={`${bpsToPct(vaultApy)}%`} />
          <Metric label="Claim Drag" value={`${bpsToPct(claimDrag)}%`} />
        </div>
        <div className="metric-divider" />
        <div className="metric-row metric-row--2">
          <Metric label="Lifetime Premium" value={fmt(lifetimePremium)} unit={label} />
          <Metric label="Lifetime Claims" value={fmt(lifetimeClaims)} unit={label} />
        </div>
      </div>

      <div className="action-block">
        <input
          type="text"
          inputMode="decimal"
          placeholder={`Amount in ${label}`}
          value={depositAmount}
          onChange={(e) => setDepositAmount(e.target.value)}
          className="field"
          spellCheck={false}
        />
        <button
          type="button"
          className="btn btn--deposit"
          onClick={onDeposit}
          disabled={!depositAmount || !address || busy !== "idle"}
        >
          {depositLabel}
        </button>
      </div>

      <div className="action-block">
        <input
          type="text"
          inputMode="decimal"
          placeholder="Shares to burn"
          value={withdrawShares}
          onChange={(e) => setWithdrawShares(e.target.value)}
          className="field"
          spellCheck={false}
        />
        <div className="withdraw-row">
          <button
            type="button"
            className="btn btn--withdraw"
            onClick={() => onWithdraw(false)}
            disabled={!withdrawShares || !address || busy !== "idle"}
          >
            {withdrawLabel}
          </button>
          <button
            type="button"
            className="btn btn--ghost btn--sm"
            onClick={() => onWithdraw(true)}
            disabled={!userShares || userShares === 0n || busy !== "idle"}
          >
            MAX
          </button>
        </div>
      </div>
    </div>
  );
}

function Stat({
  label,
  value,
  unit,
  tone,
}: {
  label: string;
  value: string;
  unit?: string;
  tone?: "pos";
}) {
  return (
    <div>
      <div className="stat-label">{label}</div>
      <div className={"stat-value" + (tone ? " stat-value--" + tone : "")}>
        {value}
        {unit && <span className="stat-unit">{unit}</span>}
      </div>
    </div>
  );
}

function Metric({ label, value, unit }: { label: string; value: string; unit?: string }) {
  return (
    <div>
      <div className="metric-label">{label}</div>
      <div className="metric-value">
        {value}
        {unit && <span className="metric-unit">{unit}</span>}
      </div>
    </div>
  );
}

function fmt(wei: bigint): string {
  const n = Number(formatEther(wei));
  if (n === 0) return "0";
  if (Math.abs(n) < 0.0001) return "<0.0001";
  // Pin to en-US so the decimal separator is always "." regardless of the
  // user's browser locale. Comma-decimal locales (fr-FR, de-DE, etc.) render
  // "99,9999" which scans like 99,999 — confusing for a balance display.
  return n.toLocaleString("en-US", { maximumFractionDigits: 4 });
}

function signedBpsToPct(bps: bigint): string {
  const n = Number(bps) / 100;
  const sign = n > 0 ? "+" : "";
  return `${sign}${n.toFixed(2)}`;
}

function bpsToPct(bps: bigint): string {
  return (Number(bps) / 100).toFixed(2);
}
