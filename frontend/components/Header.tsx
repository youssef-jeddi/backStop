"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Aperture } from "@/components/Aperture";

export function Header() {
  const pathname = usePathname();
  return (
    <header className="topbar">
      <div className="topbar-inner">
        <Link href="/" className="brand">
          <Aperture size={26} color="#ffffff" />
          <span className="brand-word">
            <span>Back</span>
            <span className="brand-rule" aria-hidden="true" />
            <span>Stop</span>
          </span>
        </Link>

        <nav className="nav">
          <Link
            href="/"
            className={"nav-link" + (pathname === "/" ? " is-active" : "")}
          >
            Dashboard
          </Link>
          <Link
            href="/faucet"
            className={"nav-link" + (pathname === "/faucet" ? " is-active" : "")}
          >
            Faucet
          </Link>
        </nav>

        <div className="wallet">
          <WalletPills />
        </div>
      </div>
    </header>
  );
}

function WalletPills() {
  return (
    <ConnectButton.Custom>
      {({ account, chain, openAccountModal, openChainModal, openConnectModal, mounted }) => {
        const ready = mounted;
        const connected = ready && account && chain;
        if (!ready) {
          return <div style={{ opacity: 0, pointerEvents: "none" }} aria-hidden="true" />;
        }
        if (!connected) {
          return (
            <button type="button" className="pill pill--connect" onClick={openConnectModal}>
              Connect wallet
            </button>
          );
        }
        if (chain.unsupported) {
          return (
            <button type="button" className="pill pill--connect" onClick={openChainModal}>
              Wrong network
            </button>
          );
        }
        return (
          <>
            <button type="button" className="pill pill--net" onClick={openChainModal}>
              <span className="net-glyph">
                <EthGlyph size={13} />
              </span>
              <span>{chain.name}</span>
              <Chevron />
            </button>
            {account.displayBalance ? (
              <div className="pill pill--bal">
                <span className="mono">{trimBalance(account.displayBalance)}</span>
                <span>ETH</span>
              </div>
            ) : null}
            <button type="button" className="pill pill--addr" onClick={openAccountModal}>
              <span className="avatar" aria-hidden="true" />
              <span className="mono">{shortAddr(account.address)}</span>
              <Chevron />
            </button>
          </>
        );
      }}
    </ConnectButton.Custom>
  );
}

function EthGlyph({ size = 14 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <polygon points="12,2 20,12 12,16 4,12" fill="currentColor" opacity="0.95" />
      <polygon points="12,17 20,13 12,22 4,13" fill="currentColor" opacity="0.6" />
    </svg>
  );
}

function Chevron() {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true" style={{ opacity: 0.6 }}>
      <path
        d="M2.5 4.5 L6 8 L9.5 4.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function shortAddr(a: string): string {
  return a.slice(0, 4) + "…" + a.slice(-4);
}

function trimBalance(s: string): string {
  // RainbowKit's displayBalance comes formatted like "4.27 ETH" — strip the unit.
  return s.replace(/\s*ETH$/i, "").trim();
}
