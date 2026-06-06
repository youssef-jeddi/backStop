"use client";

import { useAccount, useReadContracts, useWriteContract } from "wagmi";
import { formatEther, parseEther, type Address } from "viem";
import { erc20Abi } from "@/lib/abis/backstopHook";
import { CONTRACTS } from "@/lib/contracts";

const MINT_AMOUNT = parseEther("1000");

export function MintCard() {
  const { address } = useAccount();
  const { writeContract, isPending } = useWriteContract();

  const { data } = useReadContracts({
    contracts: address
      ? [
        { address: CONTRACTS.usdc, abi: erc20Abi, functionName: "balanceOf", args: [address] },
        { address: CONTRACTS.weth, abi: erc20Abi, functionName: "balanceOf", args: [address] },
      ]
      : [],
    query: { enabled: Boolean(address) },
  });

  const usdcBal = data?.[0]?.result as bigint | undefined;
  const wethBal = data?.[1]?.result as bigint | undefined;

  function mintTo(token: Address) {
    if (!address) return;
    writeContract({
      address: token,
      abi: erc20Abi,
      functionName: "mint",
      args: [address, MINT_AMOUNT],
    });
  }

  return (
    <div className="card card--warn faucet-card">
      <div className="sec-label sec-label--warn">Demo Faucet</div>
      <p className="card-lede">
        Mock tokens have a public mint. Grab 1000 of each to play with.
      </p>
      <div className="dual-grid">
        <FaucetCol
          label="Mint 1000 mUSDC"
          balance={usdcBal}
          disabled={!address || isPending}
          onClick={() => mintTo(CONTRACTS.usdc)}
        />
        <FaucetCol
          label="Mint 1000 mWETH"
          balance={wethBal}
          disabled={!address || isPending}
          onClick={() => mintTo(CONTRACTS.weth)}
        />
      </div>
    </div>
  );
}

function FaucetCol({
  label,
  balance,
  disabled,
  onClick,
}: {
  label: string;
  balance: bigint | undefined;
  disabled: boolean;
  onClick: () => void;
}) {
  return (
    <div className="mint-col">
      <button type="button" className="btn btn--warn" onClick={onClick} disabled={disabled}>
        {label}
      </button>
      <div className="balance-line">
        balance: <span className="mono">{balance !== undefined ? formatEther(balance) : "—"}</span>
      </div>
    </div>
  );
}
