"use client";

import { useReadContracts } from "wagmi";
import { backstopHookAbi } from "@/lib/abis/backstopHook";
import { CONTRACTS } from "@/lib/contracts";

export function PoolStats() {
  const { data } = useReadContracts({
    contracts: [
      { address: CONTRACTS.hook, abi: backstopHookAbi, functionName: "getCurrentVolatility" },
      { address: CONTRACTS.hook, abi: backstopHookAbi, functionName: "getCurrentPremiumRate" },
    ],
  });

  const vol = data?.[0]?.result as bigint | undefined;
  const rate = data?.[1]?.result as bigint | undefined;

  return (
    <div className="card">
      <div className="sec-label">Pool State</div>
      <div className="pool-state-grid">
        <div>
          <div className="big-stat-label">Realized volatility</div>
          <BigStat value={vol !== undefined ? bpsToPct(vol) : "—"} />
        </div>
        <div>
          <div className="big-stat-label">Premium rate</div>
          <div className="big-stat-sub">share of LP fees routed to underwriters</div>
          <BigStat value={rate !== undefined ? bpsToPct(rate) : "—"} />
        </div>
      </div>
    </div>
  );
}

function BigStat({ value }: { value: string }) {
  const showPct = value !== "—";
  return (
    <div className="big-stat-value">
      {value}
      {showPct && <span className="pct">%</span>}
    </div>
  );
}

function bpsToPct(bps: bigint): string {
  return (Number(bps) / 100).toFixed(2);
}
