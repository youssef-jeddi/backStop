import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { sepolia, foundry } from "wagmi/chains";
import { http } from "viem";

const SEPOLIA_RPC = process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ?? "https://sepolia.gateway.tenderly.co";

export const wagmiConfig = getDefaultConfig({
  appName: "BackStop",
  projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? "00000000000000000000000000000000",
  chains: [sepolia, foundry],
  transports: {
    [sepolia.id]: http(SEPOLIA_RPC),
    [foundry.id]: http("http://localhost:8545"),
  },
  ssr: true,
});
