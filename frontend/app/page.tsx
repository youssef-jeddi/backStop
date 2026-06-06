"use client";

import { useWriteContract } from "wagmi";
import { Header } from "@/components/Header";
import { PoolStats } from "@/components/PoolStats";
import { PositionCard } from "@/components/PositionCard";
import { backstopHookAbi } from "@/lib/abis/backstopHook";
import { CONTRACTS } from "@/lib/contracts";

export default function HomePage() {
  const { writeContract, isPending } = useWriteContract();

  function onSweep() {
    writeContract({
      address: CONTRACTS.hook,
      abi: backstopHookAbi,
      functionName: "sweepToVaults",
    });
  }

  return (
    <div className="app">
      <div className="bg-glow" />
      <Header />
      <main className="main">
        <div className="view">
          <PoolStats />

          <div className="pools-grid">
            <PositionCard label="USDC" token={CONTRACTS.usdc} />
            <PositionCard label="WETH" token={CONTRACTS.weth} />
          </div>

          <div className="sweep-link-row">
            <button type="button" onClick={onSweep} disabled={isPending} className="text-link">
              sweep pending premium to vaults
            </button>
          </div>
        </div>
      </main>
    </div>
  );
}
