"use client";

import { Header } from "@/components/Header";
import { MintCard } from "@/components/MintCard";
import { SimulateYieldCard } from "@/components/SimulateYieldCard";

export default function FaucetPage() {
  return (
    <div className="app">
      <div className="bg-glow" />
      <Header />
      <main className="main">
        <div className="view view--narrow">
          <div className="page-head">
            <h1 className="page-title">Demo helpers</h1>
            <p className="page-lede">
              BackStop on Sepolia uses mock tokens + mock vaults. These buttons mint test tokens
              to your wallet and trigger synthetic yield events on the vaults, both behaviours
              that would happen automatically in production with real tokens + real yield
              strategies.
            </p>
          </div>
          <MintCard />
          <SimulateYieldCard />
        </div>
      </main>
    </div>
  );
}
