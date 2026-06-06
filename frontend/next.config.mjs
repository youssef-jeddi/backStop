/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  webpack: (config) => {
    // Silence harmless missing-optional-dep warnings from RainbowKit /
    // wagmi transitive deps. These are React Native shims + a dev-only
    // pino formatter that aren't used in a browser build.
    config.resolve.fallback = {
      ...(config.resolve.fallback ?? {}),
      "@react-native-async-storage/async-storage": false,
      "pino-pretty": false,
    };
    return config;
  },
};
export default nextConfig;
